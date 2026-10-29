{ service ? "Claude Code-credentials" }: pkgs:
import ./caddy.nix {
  name = "anthropic";
  host = "api.anthropic.com";
  headers.Authorization = [ "Bearer {env.ZANDY_GATEWAY_TOKEN}" ];
  addHeaders.anthropic-beta = [ "oauth-2025-04-20" ];
} pkgs // {
  secrets.ZANDY_GATEWAY_TOKEN.keychain = {
    inherit service;
    field = [ "claudeAiOauth" "accessToken" ];
  };
}
