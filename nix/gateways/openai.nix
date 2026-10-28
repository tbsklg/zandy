{ env ? "OPENAI_API_KEY", upstream ? "https://api.openai.com" }: _: {
  name = "openai";
  inherit upstream;
  auth.header = { name = "authorization"; prefix = "Bearer "; inherit env; };
}
