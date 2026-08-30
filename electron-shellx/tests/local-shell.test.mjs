import assert from "node:assert/strict";
import test from "node:test";
import { localShellArgs } from "../dist/main/local-shell.js";

test("空启动命令保持 zsh 登录 shell 行为", () => {
  assert.deepEqual(localShellArgs("/bin/zsh", ""), ["-l"]);
  assert.deepEqual(localShellArgs("/bin/zsh", "   "), ["-l"]);
});

test("zsh 启动命令通过独立 argv 传递", () => {
  assert.deepEqual(localShellArgs("/bin/zsh", " exec zsh -il "), ["-l", "-c", "exec zsh -il"]);
});

test("fish 使用自身的登录和命令参数", () => {
  assert.deepEqual(localShellArgs("/opt/homebrew/bin/fish", "exec fish -l"), ["--login", "--command", "exec fish -l"]);
});

test("自定义 shell 的非空命令仍通过独立参数传递", () => {
  assert.deepEqual(localShellArgs("/usr/local/bin/custom-shell", "echo ready"), ["-c", "echo ready"]);
});
