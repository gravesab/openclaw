#!/usr/bin/env bash
set -euo pipefail

# Sync local manuals to Intel Mini RanchBrain folders that match asset registry paths.
SSH_KEY="${PROPERTYMANAGER_INTEL_SSH_KEY:-$HOME/.ssh/propertymanager_intelmini}"
INTEL="${PROPERTYMANAGER_INTEL_HOST:-gravesab@intelmini}"
SRC_PDFS="${PROPERTYMANAGER_MANUALS_SRC:-$HOME/Downloads/PDFs}"
SRC_BOOKS="${PROPERTYMANAGER_IBOOKS_SRC:-$HOME/Library/Mobile Documents/iCloud~com~apple~iBooks/Documents}"
REMOTE_RB="/mnt/ai-storage/ranchbrain/manuals"

sync_one() {
  local dest="$1"
  local file="$2"
  local src_dir="$3"
  local local_path="$src_dir/$file"
  if [[ ! -f "$local_path" ]]; then
    echo "skip missing: $file"
    return 0
  fi
  echo "→ $dest/$file"
  ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 "$INTEL" "mkdir -p \"$REMOTE_RB/$dest\""
  scp -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 \
    "$local_path" "$INTEL:$REMOTE_RB/$dest/"
}

echo "Syncing asset manuals to $INTEL:$REMOTE_RB"

# Downloads/PDFs
sync_one "DR-Power/DR-Field-Mower" "DR Field Mower Manual.pdf" "$SRC_PDFS"
sync_one "DR-Power/DR-SP22" "DR SP22 Mower Safety Manual.pdf" "$SRC_PDFS"
sync_one "Home/Ecowater" "EcoWater Owners Manual.pdf" "$SRC_PDFS"
sync_one "Home/Generator" "Generator - Generrac Air-Cooled Generator Manual.pdf" "$SRC_PDFS"
sync_one "Home/Pool" "Pool Tmer User Manual.pdf" "$SRC_PDFS"
sync_one "Home/Grill" "Pii Boss Grill_PB1600CS_OwnersManual_110V_EN_.pdf" "$SRC_PDFS"
sync_one "Home/Locks" "Yale Assure Manual.pdf" "$SRC_PDFS"
sync_one "Home/Locks" "Yale Locks_How to install Door Sence.pdf" "$SRC_PDFS"
sync_one "Landscape/Chainsaws/Husqvarna" "Husqvarna 435 440 Operator's Manual.pdf" "$SRC_PDFS"
sync_one "Landscape/Chainsaws/Husqvarna" "Husqvarna 450 Rancher Operator's Manual.pdf" "$SRC_PDFS"
sync_one "Smart-Home/Eufy" "Eufy X10 Pro Omni Setup Guide.pdf" "$SRC_PDFS"
sync_one "Home/Canning" "Nesco Canning Guide NPC-9.pdf" "$SRC_PDFS"
sync_one "Property/Inspections" "Property_Back 20 Acre Inspection Report.pdf" "$SRC_PDFS"

# iBooks asset manuals
sync_one "John-Deere/JD-1025R-Tractor" "1E and 1R Series Compact Utility Tractors - 1023E 1025R 1026R.pdf" "$SRC_BOOKS"
sync_one "Equipment/Toro/Toro-22in-Kohler-Mower" "UseandCareManual-Toro-22inKohlerHighWheelVariableSpeedGasSelfPropelledMower.pdf" "$SRC_BOOKS"
sync_one "Equipment/Toro/Toro-22in-Kohler-Mower" "ReplacementPartList-Toro-22inKohlerHighWheelVariableSpeedGasSelfPropelledMower.pdf" "$SRC_BOOKS"
sync_one "Vehicles/Ram-1500" "Ram 1500 Media Center Update Instructions.pdf" "$SRC_BOOKS"
sync_one "Vehicles/Toyota-RAV4" "toyoto rav4 post oak.pdf" "$SRC_BOOKS"
sync_one "Vehicles/GMC-AT4" "366601A_AT4_SO_MANUAL_160516.pdf" "$SRC_BOOKS"
sync_one "Home/Jacuzzi" "Strong-Spas-Manual2020sm.pdf" "$SRC_BOOKS"
sync_one "Home/Pool" "power-ionizer.pdf" "$SRC_BOOKS"
sync_one "Home/Pool" "Natures Pure Watercare Program.pdf" "$SRC_BOOKS"
sync_one "Home/Locks" "yale-yrd226-yrd426-assure-lock-touchscreen-deadbolt-installation-and-programming-manual-optimized.pdf" "$SRC_BOOKS"
sync_one "Smart-Home/Eufy" "X10 Pro Omni_T2351_EN_Manual.pdf" "$SRC_BOOKS"
sync_one "Landscape/Trimmers/Homelite" "Homelite UT10947D Manuals.pdf" "$SRC_BOOKS"

echo "Manual sync complete. See ranchbrain/manuals/ASSET_MANUAL_INDEX.md on Intel."
