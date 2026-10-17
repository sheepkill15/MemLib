// Pinterest sign-in for Memlib. The Pinterest app secret cannot ship inside the
// desktop or Android app, so this function holds it and performs the token
// requests. It stores nothing: tokens are returned to the device that asked.
//
//   GET  ?start=1&state=…       Redirects to Pinterest's consent page.
//   GET  ?code=…&state=…        Pinterest's redirect target. Hands the code back
//                               to the app (Android deep link or the Windows
//                               loopback listener named in the state).
//   POST {grant_type, code}     Exchanges an authorization code for tokens.
//   POST {grant_type, refresh_token}  Refreshes an access token.
//
// Deploy with `supabase functions deploy pinterest-oauth --no-verify-jwt`
// (the browser redirects carry no Supabase session) and set the secrets
// PINTEREST_APP_ID and PINTEREST_APP_SECRET. Register this function's URL,
// https://<project>.supabase.co/functions/v1/pinterest-oauth, as the redirect
// URI of the Pinterest app.

const appId = Deno.env.get("PINTEREST_APP_ID") ?? "";
const appSecret = Deno.env.get("PINTEREST_APP_SECRET") ?? "";
const redirectUri = Deno.env.get("PINTEREST_REDIRECT_URI") ??
  `${Deno.env.get("SUPABASE_URL")}/functions/v1/pinterest-oauth`;
const scopes = [
  "user_accounts:read",
  "boards:read",
  "boards:read_secret",
  "pins:read",
  "pins:read_secret",
].join(",");

/// The state is "<nonce>.<target>", where the target says how to reach the
/// app. Only these two fixed destinations are allowed, so the function cannot
/// be used to redirect anywhere else.
function appCallback(state: string | null): URL | null {
  const match = state?.match(/^[A-Za-z0-9_-]{16,128}\.(android|w(\d{4,5}))$/);
  if (!match) return null;
  if (match[1] === "android") {
    return new URL("com.sheepkill15.memlib://pinterest-callback");
  }
  const port = Number(match[2]);
  if (port < 1024 || port > 65535) return null;
  return new URL(`http://127.0.0.1:${port}/pinterest-callback`);
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function redirect(location: URL): Response {
  return new Response(null, {
    status: 302,
    headers: { location: location.toString(), "cache-control": "no-store" },
  });
}

Deno.serve(async (request) => {
  if (!appId || !appSecret) {
    return json({ error: "Pinterest is not configured on the server" }, 503);
  }
  const url = new URL(request.url);

  if (request.method === "GET") {
    const state = url.searchParams.get("state");
    const callback = appCallback(state);
    if (!callback || !state) {
      return new Response("Invalid Pinterest sign-in request", { status: 400 });
    }
    if (url.searchParams.has("start")) {
      const authorize = new URL("https://www.pinterest.com/oauth/");
      authorize.search = new URLSearchParams({
        client_id: appId,
        redirect_uri: redirectUri,
        response_type: "code",
        scope: scopes,
        state,
      }).toString();
      return redirect(authorize);
    }
    // Supabase's own deep-link handler reacts to `code` and `error`, so the
    // app receives them under Pinterest-specific names.
    const code = url.searchParams.get("code");
    if (code) {
      callback.searchParams.set("pinterest_code", code);
    } else {
      callback.searchParams.set(
        "pinterest_error",
        url.searchParams.get("error") ?? "access_denied",
      );
    }
    callback.searchParams.set("state", state);
    return redirect(callback);
  }

  if (request.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }
  let body: Record<string, unknown>;
  try {
    body = await request.json();
  } catch {
    return json({ error: "Expected a JSON body" }, 400);
  }
  const form = new URLSearchParams();
  if (body.grant_type === "authorization_code" && typeof body.code === "string") {
    form.set("grant_type", "authorization_code");
    form.set("code", body.code);
    form.set("redirect_uri", redirectUri);
    form.set("continuous_refresh", "true");
  } else if (
    body.grant_type === "refresh_token" && typeof body.refresh_token === "string"
  ) {
    form.set("grant_type", "refresh_token");
    form.set("refresh_token", body.refresh_token);
  } else {
    return json({ error: "Unsupported grant" }, 400);
  }

  const response = await fetch("https://api.pinterest.com/v5/oauth/token", {
    method: "POST",
    headers: {
      authorization: `Basic ${btoa(`${appId}:${appSecret}`)}`,
      "content-type": "application/x-www-form-urlencoded",
    },
    body: form,
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    // 400 tells the app the code or refresh token is no longer valid.
    return json(
      { error: data.message ?? `Pinterest returned ${response.status}` },
      response.status >= 400 && response.status < 500 ? 400 : 502,
    );
  }
  return json({
    access_token: data.access_token,
    refresh_token: data.refresh_token,
    expires_in: data.expires_in,
    refresh_token_expires_in: data.refresh_token_expires_in,
    scope: data.scope,
  });
});
