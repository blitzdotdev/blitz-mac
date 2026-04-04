import Testing
@testable import Blitz

@Test func agentStartupProcessUsesGuardedShellWrapper() {
    let startup = TerminalManager.agentStartupProcess(
        agent: .codex,
        prompt: "inspect this",
        skipPermissions: true
    )

    #expect(startup.executable == "/bin/sh")
    #expect(startup.execName == "/bin/sh")
    #expect(startup.args.count == 2)
    #expect(startup.args.first == "-c")

    let script = startup.args[1]
    #expect(script.contains("cleanup() {"))
    #expect(script.contains("trap cleanup EXIT HUP INT TERM"))
    #expect(script.contains("kill -HUP 0 >/dev/null 2>&1 || true"))
    #expect(script.contains("kill -TERM 0 >/dev/null 2>&1 || true"))
    #expect(script.contains("/usr/bin/python3 - <<'PY' &"))
    #expect(script.contains("parent_pid = os.getppid()"))
    #expect(script.contains("leader = os.getpgrp()"))
    #expect(script.contains("os.tcsetpgrp(0, leader)"))
    #expect(script.contains("'codex' '--dangerously-bypass-approvals-and-sandbox' 'inspect this'"))
}
