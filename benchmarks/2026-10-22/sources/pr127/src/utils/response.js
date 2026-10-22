export const sendJson = (res, statusCode, payload) => {
  res.setHeader(
    'Content-Type',
    'application/json'
  );

  res.statusCode = statusCode;
  res.end(JSON.stringify(payload));
};

export const sendError = (res, statusCode, message) => {
  res.statusCode = statusCode;
  sendJson(res, statusCode, {
    error: message
  });
};