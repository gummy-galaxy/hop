import * as vscode from "vscode";

import { confirmation, nothingToClean, summary } from "./clean";
import * as hop from "./hop";
import { recordRecent } from "./items";
import { pick } from "./picker";
import * as workspace from "./workspace";

const RECENT_KEY = "hop.recent";

export function activate(context: vscode.ExtensionContext): void {
	let latest: hop.HopList | undefined;
	let refreshing: Promise<hop.HopList> | undefined;

	const hopPath = () =>
		hop.resolveHopPath(context.extensionPath, vscode.workspace.getConfiguration("hop").get("path", ""));
	const remember = (list: hop.HopList) => {
		latest = list;
		updateStatus();
		return list;
	};
	const cached = () => hop.list(hopPath(), false).then(remember);
	const refresh = () => {
		refreshing ??= hop
			.list(hopPath(), true)
			.then(remember)
			.finally(() => {
				refreshing = undefined;
			});
		return refreshing;
	};
	const recent = () => context.globalState.get<string[]>(RECENT_KEY, []);

	const status = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 100);
	status.command = "hop.go";
	status.tooltip = "Hop: Go";
	context.subscriptions.push(status);

	function updateStatus(): void {
		const current = workspace.activePath();
		if (current === undefined) {
			status.hide();
			return;
		}
		const worktree = latest && hop.allWorktrees(latest).find((candidate) => candidate.path === current);
		if (!worktree) {
			status.hide();
			return;
		}
		const name = `${worktree.repository.name} · ${worktree.branch ?? "detached"}`;
		const pullRequest = worktree?.pr ? ` · #${worktree.pr.number}` : "";
		status.text = `$(git-branch) ${name}${pullRequest}`;
		status.show();
	}

	async function go(worktree: hop.HopWorktree): Promise<void> {
		await context.globalState.update(RECENT_KEY, recordRecent(recent(), worktree.path));
		await workspace.switchTo({
			path: worktree.path,
		});
		updateStatus();
	}

	const report = (error: unknown) =>
		void vscode.window.showErrorMessage(error instanceof Error ? error.message : String(error));

	// Lists what Hop would remove, asks before removing it, then refreshes so **Hop: Go** stops offering it.
	async function clean(mode: hop.CleanMode): Promise<void> {
		const cwd = workspace.activePath();
		const planned = await vscode.window.withProgress(
			{ location: vscode.ProgressLocation.Window, title: "Hop: checking worktrees" },
			() => hop.clean(hopPath(), mode, true, cwd)
		);
		const question = confirmation(mode, planned);
		if (!question) {
			void vscode.window.showInformationMessage(nothingToClean(mode, planned));
			return;
		}
		const choice = await vscode.window.showWarningMessage(
			question.message,
			{ modal: true, detail: question.detail },
			"Remove"
		);
		if (choice !== "Remove") {
			return;
		}
		const outcomes = await vscode.window.withProgress(
			{ location: vscode.ProgressLocation.Notification, title: "Hop: removing worktrees" },
			() => hop.clean(hopPath(), mode, false, cwd)
		);
		void vscode.window.showInformationMessage(summary(outcomes));
		await refresh();
	}

	context.subscriptions.push(
		vscode.commands.registerCommand("hop.go", async () => {
			const target = await pick({ cached, refresh, recent, currentPath: workspace.activePath });
			if (target?.kind === "worktree") {
				await go(target.worktree).catch(report);
			} else if (target) {
				// `hop to` opens a worktree it finds after refreshing, or checks the PR out.
				const expression =
					target.kind === "pullRequest"
						? `${target.pullRequest.repository}#${target.pullRequest.number}`
						: `${target.repository}#${target.number}`;
				await vscode.window
					.withProgress(
						{ location: vscode.ProgressLocation.Notification, title: `Hop: checking out ${expression}` },
						() => hop.to(hopPath(), expression)
					)
					.then(undefined, report);
			}
		}),
		vscode.commands.registerCommand("hop.refresh", () =>
			vscode.window.withProgress(
				{ location: vscode.ProgressLocation.Window, title: "Hop: refreshing worktrees" },
				() => refresh().then(() => undefined, report)
			)
		),
		vscode.commands.registerCommand("hop.cleanMerged", () => clean("merged").catch(report)),
		vscode.commands.registerCommand("hop.cleanAll", () => clean("all").catch(report)),
		// `hop <expr>` in a terminal hands off here: vscode://vocksel.hop/to?path=<worktree>
		vscode.window.registerUriHandler({
			handleUri: async (uri) => {
				if (uri.path !== "/to") {
					return;
				}
				const requested = new URLSearchParams(uri.query).get("path");
				try {
					// Only mount folders Hop already knows about, never arbitrary paths from a link.
					const find = (list: hop.HopList) =>
						hop.allWorktrees(list).find((worktree) => worktree.path === requested);
					const worktree = find(await cached()) ?? find(await refresh());
					if (!worktree) {
						throw new Error(`Hop does not know a worktree at ${requested}`);
					}
					await go(worktree);
				} catch (error) {
					report(error);
				}
			},
		}),
		vscode.workspace.onDidChangeWorkspaceFolders(updateStatus)
	);

	if (workspace.activePath() !== undefined) {
		updateStatus();
		cached().catch(() => undefined);
	}
}

export function deactivate(): void {}
