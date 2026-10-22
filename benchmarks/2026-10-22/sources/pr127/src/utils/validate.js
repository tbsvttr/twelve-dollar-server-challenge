import { ERRORS } from './errors.js'
import { sendError } from './response.js';

export const isPositiveIntegerString = (value) => {
  if (typeof value !== 'string') {
    return false;
  }

  const num = Number(value);

  return (
    Number.isInteger(num) &&
    num > 0 &&
    String(num) === value
  );
};

export const validatePostBody = (body, res) => {

    if (typeof body !== 'string') {
        sendError(res, 400, ERRORS.BODY_REQUIRED);
        return null;
    }

    const trimmedBody = body.trim();

    if (!trimmedBody) {
        sendError(res, 400, ERRORS.BODY_REQUIRED);
        return null;
    }

    if (trimmedBody.length > 500) {
        sendError(
            res,
            400,
            ERRORS.BODY_TOO_LONG
        );

        return null;
    }

    return trimmedBody;
};