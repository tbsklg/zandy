{ env ? "ANTHROPIC_API_KEY" }: _: {
  name = "anthropic";
  upstream = "https://api.anthropic.com";
  auth.header = { name = "x-api-key"; inherit env; };
}
