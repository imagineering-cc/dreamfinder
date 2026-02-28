import { z } from "zod";

/**
 * Zod schema for all environment variables.
 * Validates and transforms raw `process.env` into typed, safe configuration.
 * Fails fast at startup if any required variable is missing or malformed.
 */
const envSchema = z.object({
  // Anthropic
  ANTHROPIC_API_KEY: z
    .string()
    .startsWith("sk-ant-", { message: "ANTHROPIC_API_KEY must start with 'sk-ant-'" }),

  // Signal
  SIGNAL_API_URL: z.string().url(),
  SIGNAL_PHONE_NUMBER: z
    .string()
    .startsWith("+", { message: "SIGNAL_PHONE_NUMBER must start with '+'" }),

  // Kan.bn
  KAN_BASE_URL: z.string().url(),
  KAN_API_KEY: z.string().min(1),

  // Outline
  OUTLINE_BASE_URL: z.string().url(),
  OUTLINE_API_KEY: z.string().min(1),

  // Radicale (optional — calendar/contacts features)
  RADICALE_BASE_URL: z.string().url().optional(),
  RADICALE_USERNAME: z.string().optional(),
  RADICALE_PASSWORD: z.string().optional(),

  // Playwright (optional — web browsing tools)
  PLAYWRIGHT_ENABLED: z
    .string()
    .default("false")
    .transform((val) => val === "true"),

  // Bot config
  BOT_NAME: z.string().default("Figment"),
  DATABASE_PATH: z.string().default("./data/bot.db"),
  LOG_LEVEL: z.enum(["debug", "info", "warn", "error"]).default("info"),
  NODE_ENV: z.enum(["development", "production", "test"]).default("development"),
});

export type Env = z.infer<typeof envSchema>;

/**
 * Parses and validates environment variables.
 * Call this once at startup — it throws a descriptive error on failure.
 */
export function parseEnv(): Env {
  const result = envSchema.safeParse(process.env);

  if (!result.success) {
    const formatted = result.error.issues
      .map((issue) => `  ${issue.path.join(".")}: ${issue.message}`)
      .join("\n");

    console.error("Environment validation failed:\n" + formatted);
    process.exit(1);
  }

  return result.data;
}

/** Validated environment — initialized by calling `parseEnv()` at startup. */
export let env: Env;

/** Set the module-level env singleton. Called once from main(). */
export function initEnv(): void {
  env = parseEnv();
}
