{ env ? "ANTHROPIC_API_KEY" }:
import ./caddy.nix {
  name = "anthropic";
  host = "api.anthropic.com";
  headers.X-Api-Key = [ "{env.${env}}" ];
}
