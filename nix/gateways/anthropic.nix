{ service ? "anthropic-api-key" }:
import ./caddy.nix {
  name = "anthropic";
  host = "api.anthropic.com";
  headers.X-Api-Key = [ "{env.ANTHROPIC_API_KEY}" ];
  secrets.ANTHROPIC_API_KEY.keychain = { inherit service; };
}
