"""Show which models the current router would use for each RanchOS process.

The configured deployment map is what is stored today. The selected chain is
what the runtime router keeps after Apple Intelligence, llama.cpp, MLX,
Ollama, and privacy rules. This module does not call a model.
"""

from __future__ import annotations

import html
from typing import Any, Mapping

from tools.ai_intelligence.routing_models import (
    AssignmentType,
    ModelAssignment,
    PrivacyTier,
    RoutingMode,
    RoutingModelError,
)
from tools.ai_intelligence.runtime_selection import (
    RuntimeFamily,
    WorkloadClass,
    runtime_family,
    select_runtime_assignments,
    workload_for_task,
)

RUNTIME_LABELS = {
    RuntimeFamily.APPLE_INTELLIGENCE: "Apple Intelligence",
    RuntimeFamily.LLAMA_CPP: "llama.cpp",
    RuntimeFamily.MLX: "MLX",
    RuntimeFamily.OLLAMA: "Ollama",
    RuntimeFamily.CLOUD: "Cloud",
}


def build_model_usage(
    deployment_map: Mapping[str, Any],
    registry: Mapping[str, Any],
) -> dict[str, Any]:
    """Return process chains and used versus unused models."""

    models = {
        str(model["id"]): model
        for model in registry.get("models", [])
        if isinstance(model, dict) and model.get("id")
    }
    processes = []
    for component in deployment_map.get("components", []):
        if isinstance(component, dict) and component.get("id"):
            processes.append(_process_view(component, models))
    processes.sort(key=lambda item: item["display_name"].lower())

    selected_ids = {
        model_id
        for process in processes
        for model_id in process["selected_model_ids"]
    }
    in_use = []
    for model_id in sorted(selected_ids):
        uses = [
            {
                "process_id": process["id"],
                "process_name": process["display_name"],
                "role": _role(process, model_id),
            }
            for process in processes
            if model_id in process["selected_model_ids"]
        ]
        record = models.get(model_id, {})
        family = _family_for_model(model_id, record)
        in_use.append(
            {
                "model_id": model_id,
                "display_name": str(record.get("display_name") or model_id),
                "runtime": RUNTIME_LABELS.get(family, "Unknown"),
                "cloud_client_attached": family is not RuntimeFamily.CLOUD,
                "uses": uses,
            }
        )
    in_use.sort(key=lambda item: (item["runtime"], item["display_name"].lower()))

    not_in_use = []
    for model_id, record in sorted(models.items()):
        if model_id in selected_ids:
            continue
        not_in_use.append(
            {
                "model_id": model_id,
                "display_name": str(record.get("display_name") or model_id),
                "reason": _unused_reason(model_id, record, processes),
            }
        )
    if not any(item["runtime"] == "llama.cpp" for item in in_use):
        not_in_use.insert(
            0,
            {
                "model_id": "llama.cpp",
                "display_name": "llama.cpp runtime",
                "reason": (
                    "Preferred open-source runtime. No llama.cpp model is "
                    "assigned, so processes use MLX or Ollama instead."
                ),
            },
        )

    return {
        "processes": processes,
        "in_use": in_use,
        "not_in_use": not_in_use,
        "llama_cpp_assigned": any(
            item["runtime"] == "llama.cpp" for item in in_use
        ),
    }


def model_usage_panel_html(snapshot: Mapping[str, Any]) -> str:
    """Render the process and model tables."""

    processes = snapshot.get("processes", [])
    in_use = snapshot.get("in_use", [])
    not_in_use = snapshot.get("not_in_use", [])
    process_rows = "".join(_process_row(process) for process in processes)
    used_rows = "".join(_used_row(model) for model in in_use)
    unused_rows = "".join(_unused_row(model) for model in not_in_use)
    llama_note = (
        "A llama.cpp model is on at least one selected chain."
        if snapshot.get("llama_cpp_assigned")
        else (
            "llama.cpp is the preferred open-source runtime, and it is not "
            "assigned yet. Apple Intelligence still comes first for lightweight "
            "private work. MLX and Ollama cover the open-source chain until a "
            "llama.cpp model is added. The cloud client is not attached."
        )
    )
    return f"""
    <div class='panel'>
        <h2>Models by process</h2>
        <p>{html.escape(llama_note)}</p>
        <p>
            Configured now is the stored assignment. Router selects is the
            chain that remains after the current runtime rules. A model can be
            stored for a process and still be left unused there.
        </p>
        <div class="status-box telemetry-section">
            <h3>OpenClaw and RanchOS processes</h3>
            <div class='table-scroll'><table class='dashboard-table'>
                <thead><tr>
                    <th>Process</th><th>Workload</th><th>Configured now</th>
                    <th>Router selects</th><th>Left unused here</th>
                </tr></thead>
                <tbody>{process_rows}</tbody>
            </table></div>
        </div>
        <div class="status-box telemetry-section" style="margin-top:14px;">
            <h3>Models in use</h3>
            <p>{len(in_use)} model(s) are on a selected chain.</p>
            <div class='table-scroll'><table class='dashboard-table'>
                <thead><tr><th>Model</th><th>Runtime</th><th>Processes</th></tr></thead>
                <tbody>{used_rows or "<tr><td colspan='3'>No selected models.</td></tr>"}</tbody>
            </table></div>
        </div>
        <div class="status-box telemetry-section" style="margin-top:14px;">
            <h3>Models not in use</h3>
            <p>{len(not_in_use)} model(s) are not on any selected chain.</p>
            <div class='table-scroll'><table class='dashboard-table'>
                <thead><tr><th>Model</th><th>Why it is unused</th></tr></thead>
                <tbody>{unused_rows or "<tr><td colspan='2'>Every registry model is selected somewhere.</td></tr>"}</tbody>
            </table></div>
        </div>
    </div>
    """


def _process_view(
    component: Mapping[str, Any],
    models: Mapping[str, Mapping[str, Any]],
) -> dict[str, Any]:
    component_id = str(component["id"])
    task_type = str(component.get("task_type") or "")
    privacy = _privacy(component.get("privacy_tier"))
    configured = _configured_ids(component)
    verification = str(component.get("verification_status") or "")
    notes: list[str] = []
    selected: list[str] = []
    if verification == "not-model-serving":
        notes.append("This process does not call a model.")
    elif task_type == "embedding":
        selected = list(configured)
        notes.append("Embeddings stay on the configured local model.")
    else:
        assignments = _assignments(component, models, privacy, task_type)
        try:
            chosen = select_runtime_assignments(
                assignments,
                privacy_tier=privacy,
                task_type=task_type,
            )
        except RoutingModelError as exc:
            notes.append(str(exc))
        else:
            selected = [item.model_id for item in chosen]
            notes.extend(_selection_notes(assignments, chosen, task_type))
    dropped = [model_id for model_id in configured if model_id not in selected]
    workload = (
        "No model"
        if verification == "not-model-serving"
        else workload_for_task(task_type).value
    )
    return {
        "id": component_id,
        "display_name": str(component.get("display_name") or component_id),
        "privacy_tier": privacy.value,
        "workload": workload,
        "configured_model_ids": configured,
        "selected_model_ids": selected,
        "unused_model_ids": dropped,
        "notes": notes,
    }


def _assignments(
    component: Mapping[str, Any],
    models: Mapping[str, Mapping[str, Any]],
    privacy: PrivacyTier,
    task_type: str,
) -> tuple[ModelAssignment, ...]:
    rows = []
    primary = component.get("primary_model")
    if isinstance(primary, str) and primary:
        rows.append((primary, AssignmentType.PRIMARY, 1))
    for index, model_id in enumerate(component.get("fallback_models") or [], start=1):
        if isinstance(model_id, str) and model_id:
            rows.append((model_id, AssignmentType.FALLBACK, index))
    component_id = str(component["id"])
    return tuple(
        ModelAssignment(
            component_id=component_id,
            component_name=str(component.get("display_name") or component_id),
            component_privacy_tier=privacy,
            task_type=task_type,
            assignment_type=assignment_type,
            priority=priority,
            model_id=model_id,
            model_name=str(models.get(model_id, {}).get("display_name") or model_id),
            provider=str(models.get(model_id, {}).get("provider") or "unknown"),
            deployment=str(models.get(model_id, {}).get("deployment") or "local"),
            model_status=str(models.get(model_id, {}).get("status") or "active"),
            routing_mode=RoutingMode.PRODUCTION_SAFE,
            human_approved=True,
        )
        for model_id, assignment_type, priority in rows
    )


def _configured_ids(component: Mapping[str, Any]) -> list[str]:
    configured = []
    primary = component.get("primary_model")
    if isinstance(primary, str) and primary:
        configured.append(primary)
    for model_id in component.get("fallback_models") or []:
        if isinstance(model_id, str) and model_id:
            configured.append(model_id)
    return configured


def _selection_notes(
    assignments: tuple[ModelAssignment, ...],
    selected: tuple[ModelAssignment, ...],
    task_type: str,
) -> list[str]:
    notes = []
    workload = workload_for_task(task_type)
    families = {runtime_family(item) for item in assignments}
    selected_families = {runtime_family(item) for item in selected}
    if (
        workload is WorkloadClass.LIGHTWEIGHT_PRIVATE
        and RuntimeFamily.APPLE_INTELLIGENCE not in families
    ):
        notes.append(
            "Apple Intelligence is preferred first and is not assigned here."
        )
    if RuntimeFamily.LLAMA_CPP not in selected_families:
        if (
            workload is WorkloadClass.LIGHTWEIGHT_PRIVATE
            and RuntimeFamily.APPLE_INTELLIGENCE in selected_families
        ):
            notes.append(
                "After Apple Intelligence, llama.cpp is the next preferred runtime and is not assigned here."
            )
        else:
            notes.append(
                "llama.cpp is preferred for this open-source work and is not assigned here."
            )
    for assignment in assignments:
        if any(item.model_id == assignment.model_id for item in selected):
            continue
        notes.append(
            f"{assignment.model_id}: {_exclusion_reason(assignment, workload)}"
        )
    return notes


def _exclusion_reason(
    assignment: ModelAssignment,
    workload: WorkloadClass,
) -> str:
    try:
        family = runtime_family(assignment)
    except RoutingModelError:
        return "The runtime is not recognized."
    if family is RuntimeFamily.CLOUD and assignment.component_privacy_tier is PrivacyTier.LOCAL:
        return "Local privacy keeps this cloud model off the process."
    if family is RuntimeFamily.CLOUD:
        return "Cloud stays behind local models and is only eligible for a large problem."
    if family is RuntimeFamily.APPLE_INTELLIGENCE:
        return "Apple Intelligence is only selected for lightweight private work."
    return "Removed by the current runtime order."


def _unused_reason(
    model_id: str,
    record: Mapping[str, Any],
    processes: list[dict[str, Any]],
) -> str:
    assigned_to = [
        process["display_name"]
        for process in processes
        if model_id in process["configured_model_ids"]
    ]
    if not assigned_to:
        deployment = str(record.get("deployment") or "")
        if deployment == "cloud":
            return "Not assigned. The cloud client is not attached."
        return "Not assigned to an OpenClaw or RanchOS process."
    excluded_from = [
        process["display_name"]
        for process in processes
        if model_id in process["unused_model_ids"]
    ]
    if excluded_from:
        return (
            "Assigned to "
            + ", ".join(excluded_from)
            + ", then left off the selected chain."
        )
    return "Assigned, but not selected."


def _family_for_model(
    model_id: str,
    record: Mapping[str, Any],
) -> RuntimeFamily | None:
    try:
        return runtime_family(
            ModelAssignment(
                component_id="registry",
                component_name="Registry",
                component_privacy_tier=PrivacyTier.LOCAL,
                task_type="knowledge",
                assignment_type=AssignmentType.PRIMARY,
                priority=1,
                model_id=model_id,
                model_name=model_id,
                provider=str(record.get("provider") or "unknown"),
                deployment=str(record.get("deployment") or "local"),
                model_status="active",
                routing_mode=RoutingMode.PRODUCTION_SAFE,
                human_approved=True,
            )
        )
    except RoutingModelError:
        return None


def _privacy(value: Any) -> PrivacyTier:
    try:
        return PrivacyTier(str(value))
    except ValueError:
        return PrivacyTier.LOCAL


def _role(process: Mapping[str, Any], model_id: str) -> str:
    selected = process.get("selected_model_ids") or []
    if selected and selected[0] == model_id:
        return "Selected first"
    return "Selected fallback"


def _chain(model_ids: list[str]) -> str:
    if not model_ids:
        return "None"
    return " → ".join(model_ids)


def _process_row(process: Mapping[str, Any]) -> str:
    notes = process.get("notes") or []
    note_html = "".join(f"<div>{html.escape(str(note))}</div>" for note in notes)
    unused = process.get("unused_model_ids") or []
    unused_text = ", ".join(unused) if unused else "None"
    return (
        "<tr>"
        f"<td><b>{html.escape(str(process['display_name']))}</b>"
        f"<div>{html.escape(str(process['privacy_tier']))}</div></td>"
        f"<td>{html.escape(str(process['workload']))}</td>"
        f"<td><code>{html.escape(_chain(list(process['configured_model_ids'])))}</code></td>"
        f"<td><code>{html.escape(_chain(list(process['selected_model_ids'])))}</code>{note_html}</td>"
        f"<td>{html.escape(unused_text)}</td>"
        "</tr>"
    )


def _used_row(model: Mapping[str, Any]) -> str:
    uses = []
    for use in model.get("uses") or []:
        label = f"{use['process_name']} ({use['role']})"
        if model.get("cloud_client_attached") is False:
            label += "; cloud client not attached"
        uses.append(label)
    return (
        "<tr>"
        f"<td><code>{html.escape(str(model['model_id']))}</code>"
        f"<div>{html.escape(str(model['display_name']))}</div></td>"
        f"<td>{html.escape(str(model['runtime']))}</td>"
        f"<td>{html.escape('; '.join(uses))}</td>"
        "</tr>"
    )


def _unused_row(model: Mapping[str, Any]) -> str:
    return (
        "<tr>"
        f"<td><code>{html.escape(str(model['model_id']))}</code>"
        f"<div>{html.escape(str(model['display_name']))}</div></td>"
        f"<td>{html.escape(str(model['reason']))}</td>"
        "</tr>"
    )
