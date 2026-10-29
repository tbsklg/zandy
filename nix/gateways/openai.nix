{ service ? "openai-api-key", host ? "api.openai.com" }:
import ./caddy.nix {
  name = "openai";
  inherit host;
  headers.Authorization = [ "Bearer {env.OPENAI_API_KEY}" ];
  secrets.OPENAI_API_KEY.keychain = { inherit service; };
}
