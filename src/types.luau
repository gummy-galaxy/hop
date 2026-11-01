local path = require("@std/path")

export type CommandResult = {
	ok: boolean,
	exitCode: number,
	stdout: string,
	stderr: string,
}

export type CommandRunner = ({ string }) -> CommandResult

export type Worktree = {
	path: path.Path,
	branch: string?,
	-- The branch on `origin` that `branch` tracks. Its name can differ from `branch`: coding agents such
	-- as Claude Code often work on a uniquely named local branch, such as `agent/fix-1a2b3c`, and push
	-- it as `agent/fix`.
	-- A PR's head is the pushed name, so Hop matches PRs against this as well as `branch`.
	upstream: string?,
	repository: string?,
	root: string?,
	head: string?,
	defaultBranch: string?,
	primary: boolean,
}

export type PullRequest = {
	number: number,
	url: string,
	branch: string,
	repository: string,
	title: string?,
	state: string?,
	draft: boolean?,
	author: string?,
}

export type Message = {
	role: string,
	text: string,
	timestamp: string?,
}

export type Session = {
	agent: "cursor" | "claude",
	id: string,
	title: string?,
	directory: string?,
	branchAtSessionTime: string?,
	updatedAt: number,
	needsAttention: boolean?,
	filesChanged: number?,
	messages: () -> () -> Message?,
}

export type Provider = {
	name: "cursor" | "claude",
	sessions: (self: Provider) -> { Session },
}

return {}
