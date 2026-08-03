export class TrustedRecordNotFoundError extends Error {}

export class TrustedRecordConflictError extends Error {}

export class TrustedRecordAccessDeniedError extends Error {
  constructor() {
    super("record is unavailable");
  }
}
