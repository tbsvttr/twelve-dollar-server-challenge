export const tryParseJson = (text) => {
  try {
    return {
      ok: true,
      value: JSON.parse(text)
    };
  } catch {
    return {
      ok: false
    };
  }
};