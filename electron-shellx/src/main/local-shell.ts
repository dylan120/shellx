import path from "node:path";

/**
 * 生成本机 shell 启动参数。
 * 空命令维持原有登录 shell；非空命令通过独立 argv 传入，避免额外字符串拼接和转义层。
 */
export function localShellArgs(shell: string, startupCommand?: string): string[] {
  const name = path.basename(shell);
  const command = startupCommand?.trim();
  if (["bash", "zsh", "sh", "ksh", "mksh"].includes(name)) return command ? ["-l", "-c", command] : ["-l"];
  if (name === "fish") return command ? ["--login", "--command", command] : ["--login"];
  return command ? ["-c", command] : [];
}
