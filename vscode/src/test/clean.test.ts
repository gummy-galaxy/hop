import * as assert from "node:assert/strict";
import { test } from "node:test";

import { confirmation, nothingToClean, summary } from "../clean";
import type { HopCleanOutcome } from "../hop";

const merged: HopCleanOutcome = {
	path: "/home/me/git/widgets-pr-5",
	repository: "example/widgets",
	number: 5,
	branch: "fix/thing",
	state: "MERGED",
	removed: false,
	branchDeleted: false,
};

const dirty: HopCleanOutcome = { ...merged, path: "/home/me/git/widgets-pr-6", number: 6, kept: "contains modified files" };

test("confirmation lists only the worktrees that would be removed", () => {
	const question = confirmation("merged", [merged, dirty]);
	assert.equal(question?.message, "Remove 1 worktree Hop checked out for merged pull requests?");
	assert.match(question?.detail ?? "", /example\/widgets#5 {2}\/home\/me\/git\/widgets-pr-5/);
	assert.doesNotMatch(question?.detail ?? "", /#6/);
});

test("nothing to clean names the worktrees Hop kept", () => {
	assert.equal(confirmation("all", [dirty]), undefined);
	assert.equal(
		nothingToClean("all", [dirty]),
		"No Hop worktrees to remove. Kept example/widgets#6  /home/me/git/widgets-pr-6."
	);
	assert.equal(nothingToClean("merged", []), "No Hop worktrees with merged pull requests");
});

test("summary counts removals and explains each worktree kept", () => {
	assert.equal(
		summary([{ ...merged, removed: true }, dirty]),
		"Hop: Removed 1 worktree; kept example/widgets#6: contains modified files."
	);
});
