import { describe, expect, it, vi } from "vitest";
import { createAuthCallbackController } from "./authCallback";

const focusedWindows: string[] = [];

vi.mock("electron", () => ({
	app: { isReady: () => true, on: () => {}, once: () => {} },
	BrowserWindow: {
		getAllWindows: () => [],
	},
	ipcMain: { on: () => {}, handle: () => {}, removeHandler: () => {} },
}));

function controller(isDev: boolean) {
	return createAuthCallbackController({ isDev, focusApp: () => focusedWindows.push("focused") });
}

describe("auth callback scheme", () => {
	it("registers the nexiitt scheme", () => {
		expect(controller(false).protocol).toBe("nexiitt");
		expect(controller(true).protocol).toBe("nexiitt-dev");
	});

	it("accepts a callback on the current scheme", () => {
		expect(controller(false).find(["nexiitt://auth/callback?code=abc"])).toBe(
			"nexiitt://auth/callback?code=abc",
		);
	});

	it("still accepts the previous single-t scheme so old links keep working", () => {
		expect(controller(false).find(["nexiit://auth/callback?code=abc"])).toBe(
			"nexiit://auth/callback?code=abc",
		);
	});

	it("keeps the dev scheme separate from the production one", () => {
		expect(controller(true).find(["nexiitt://auth/callback?code=abc"])).toBeNull();
		expect(controller(true).find(["nexiit://auth/callback?code=abc"])).toBeNull();
		expect(controller(true).find(["nexiitt-dev://auth/callback?code=abc"])).toBe(
			"nexiitt-dev://auth/callback?code=abc",
		);
	});

	it("rejects any other scheme", () => {
		for (const url of [
			"https://auth/callback?code=abc",
			"recordly://auth/callback?code=abc",
			"openscreen://auth/callback?code=abc",
			"nexiitt://evil/callback?code=abc",
		]) {
			expect(controller(false).find([url])).toBeNull();
		}
	});

	it("rejects credentials embedded in the callback URL", () => {
		expect(controller(false).find(["nexiitt://user:pass@auth/callback?code=abc"])).toBeNull();
	});

	it("rejects an over-long callback URL", () => {
		expect(controller(false).find([`nexiitt://auth/callback?code=${"a".repeat(9000)}`])).toBeNull();
	});

	it("reports a valid callback and focuses the app", () => {
		focusedWindows.length = 0;
		expect(controller(false).dispatch("nexiitt://auth/callback?code=abc")).toBe(true);
		expect(focusedWindows).toEqual(["focused"]);
	});

	it("reports false for an unrelated URL", () => {
		expect(controller(false).dispatch("https://example.com")).toBe(false);
	});
});
