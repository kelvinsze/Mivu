export interface ApiErrorPayload {
  error: {
    code: string;
    message: string;
  };
}

export function createErrorResponse(code: string, message: string, status: number = 400): Response {
  const payload: ApiErrorPayload = {
    error: {
      code,
      message,
    },
  };

  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
    },
  });
}

export function createJsonResponse<T>(data: T, status: number = 200, headers: HeadersInit = {}): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      ...headers,
    },
  });
}
