import type { CleanMode, HopCleanOutcome } from "./hop";

function label(outcome: HopCleanOutcome): string {
	return `${outcome.repository}#${outcome.number}  ${outcome.path}`;
}

function plural(count: number, noun: string): string {
	return `${count} ${noun}${count === 1 ? "" : "s"}`;
}

// The question shown before anything is removed. It is undefined when the dry run found no checkouts,
// or Hop would keep every one it found.
export function confirmation(
	mode: CleanMode,
	outcomes: HopCleanOutcome[]
): { message: string; detail: string } | undefined {
	const removable = outcomes.filter((outcome) => outcome.kept === undefined);
	if (removable.length === 0) {
		return undefined;
	}
	const which = mode === "merged" ? "for merged pull requests" : "for pull requests";
	return {
		message: `Remove ${plural(removable.length, "worktree")} Hop checked out ${which}?`,
		detail: [
			...removable.map(label),
			"",
			"Branches are deleted only when they match the merged pull request.",
		].join("\n"),
	};
}

export function nothingToClean(mode: CleanMode, outcomes: HopCleanOutcome[]): string {
	const kept = outcomes.filter((outcome) => outcome.kept !== undefined);
	const base = mode === "merged" ? "No Hop worktrees with merged pull requests" : "No Hop worktrees to remove";
	return kept.length === 0 ? base : `${base}. Kept ${kept.map(label).join(", ")}.`;
}

export function summary(outcomes: HopCleanOutcome[]): string {
	const removed = outcomes.filter((outcome) => outcome.removed);
	const kept = outcomes.filter((outcome) => outcome.kept !== undefined);
	const parts = [`Removed ${plural(removed.length, "worktree")}`];
	for (const outcome of kept) {
		parts.push(`kept ${outcome.repository}#${outcome.number}: ${outcome.kept}`);
	}
	return `Hop: ${parts.join("; ")}.`;
}
