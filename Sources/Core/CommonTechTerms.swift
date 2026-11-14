/// English terms commonly embedded in non-English dictation that
/// single-locale speech models mishear. Biases recognition only; never
/// sent to the LLM prompt. Order matters: most common first, because the
/// composed vocabulary is capped at 100 entries shared with user terms.
enum CommonTechTerms {
    static let terms: [String] = [
        "deploy", "commit", "branch", "merge", "rebase", "pull request",
        "push", "pipeline", "release", "rollback", "hotfix", "build",
        "debug", "bug", "feature", "feature flag", "backlog", "sprint",
        "standup", "review", "code review", "refactor", "framework",
        "frontend", "backend", "full stack", "endpoint", "API", "SDK",
        "CLI", "IDE", "token", "login", "logout", "email", "browser",
        "cloud", "server", "database", "cache", "script", "query",
        "deadline", "feedback", "meeting", "call", "chat", "link",
        "download", "upload", "update", "upgrade", "setup", "workflow",
        "dashboard", "template", "plugin", "widget", "mockup", "layout",
        "design system", "product manager", "roadmap", "milestone",
        "open source", "repository", "issue", "ticket", "changelog",
        "unit test", "integration test", "staging", "production",
        "localhost", "container", "microservice", "serverless",
        "machine learning", "prompt", "chatbot", "streaming",
        "GitHub", "GitLab", "Xcode", "Slack", "Notion", "Figma",
        "Docker", "Kubernetes", "Linux", "Swift", "SwiftUI", "Python",
        "JavaScript", "TypeScript", "React", "Node", "Rust", "Go",
    ]
}
