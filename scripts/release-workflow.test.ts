import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

type Workflow = {
  jobs: Record<
    string,
    { steps: { name?: string; with?: { script?: string } }[] }
  >;
};

function script(file: string, job: string, name: string): string {
  const workflow = Bun.YAML.parse(
    readFileSync(
      resolve(import.meta.dirname, "../.github/workflows", file),
      "utf8",
    ),
  ) as Workflow;
  const source = workflow.jobs[job].steps.find((step) => step.name === name)
    ?.with?.script;
  if (!source) throw new Error(`Missing workflow script: ${name}`);
  return source;
}

const prepare = script(
  "release.yml",
  "create-release",
  "Select or create release",
);
const publish = script(
  "release.yml",
  "publish-release",
  "Publish verified release",
);
const uploadGuard = script(
  "build.yml",
  "build",
  "Require a draft before uploading release installers",
);
const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;

function execute(source: string, github: unknown, tag = "v0.2.0") {
  const summary = {
    addHeading: () => summary,
    addLink: () => summary,
    addRaw: () => summary,
    write: async () => {},
  };
  return new AsyncFunction("github", "context", "core", "process", source)(
    github,
    { repo: { owner: "owner", repo: "yanyu" } },
    { info: () => {}, summary },
    { env: { RELEASE_TAG: tag, RELEASE_SHA: "commit", RELEASE_ID: "42" } },
  );
}

test("release preparation reuses an existing draft and refuses a published release", async () => {
  const release = { id: 42, tag_name: "v0.2.0", draft: true };
  const github = {
    paginate: async () => [release],
    rest: { repos: { listReleases: () => {} } },
  };
  expect(await execute(prepare, github)).toBe(42);
  release.draft = false;
  await expect(execute(prepare, github)).rejects.toThrow("already published");
});

test("release preparation creates a draft against the resolved tagged commit", async () => {
  const requests: unknown[] = [];
  const github = {
    paginate: async () => [],
    rest: {
      repos: {
        listReleases: () => {},
        createRelease: async (request: unknown) => {
          requests.push(request);
          return { data: { id: 42 } };
        },
      },
    },
  };
  expect(await execute(prepare, github, "v0.2.0-1")).toBe(42);
  expect(requests).toEqual([
    {
      owner: "owner",
      repo: "yanyu",
      tag_name: "v0.2.0-1",
      target_commitish: "commit",
      name: "v0.2.0-1",
      draft: true,
      prerelease: true,
      generate_release_notes: true,
    },
  ]);
});

test("individual build retries cannot upload to a published release", async () => {
  const release = { draft: true };
  const github = {
    rest: { repos: { getRelease: async () => ({ data: release }) } },
  };
  await execute(uploadGuard, github);
  release.draft = false;
  await expect(execute(uploadGuard, github)).rejects.toThrow(
    "already published",
  );
});

test.each([
  { tag: "v0.2.0", prerelease: false, makeLatest: "legacy" },
  { tag: "v0.2.0-1", prerelease: true, makeLatest: "false" },
])("publishing $tag preserves the correct Latest policy", async (expected) => {
  const requests: unknown[] = [];
  const state = { sha: "commit", draft: true, assets: [{}] };
  const github = {
    rest: {
      git: {
        getRef: async () => ({ data: { object: { type: "tag", sha: "tag" } } }),
        getTag: async () => ({
          data: { object: { type: "commit", sha: state.sha } },
        }),
      },
      repos: {
        getRelease: async () => ({
          data: { draft: state.draft, tag_name: expected.tag },
        }),
        listReleaseAssets: async () => ({ data: state.assets }),
        updateRelease: async (request: unknown) => {
          requests.push(request);
          return { data: { html_url: "https://example.com/release" } };
        },
      },
    },
  };
  await execute(publish, github, expected.tag);
  expect(requests).toEqual([
    {
      owner: "owner",
      repo: "yanyu",
      release_id: 42,
      draft: false,
      prerelease: expected.prerelease,
      make_latest: expected.makeLatest,
    },
  ]);

  requests.length = 0;
  state.sha = "moved";
  await expect(execute(publish, github, expected.tag)).rejects.toThrow("moved");
  state.sha = "commit";
  state.draft = false;
  await expect(execute(publish, github, expected.tag)).rejects.toThrow("draft");
  state.draft = true;
  state.assets = [];
  await expect(execute(publish, github, expected.tag)).rejects.toThrow(
    "no installers",
  );
  expect(requests).toEqual([]);
});
