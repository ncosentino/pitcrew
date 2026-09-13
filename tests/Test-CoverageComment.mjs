import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import test from 'node:test';

const require = createRequire(import.meta.url);
const {
  COMMENT_MARKER,
  upsertCoverageComment
} = require('../scripts/coverage/Upsert-GoCoverageComment.cjs');

const context = {
  serverUrl: 'https://github.com',
  repo: {
    owner: 'example',
    repo: 'pitcrew'
  },
  issue: {
    number: 196
  },
  runId: 123456789
};
const report = '## Go coverage\n\n| Combined | 8 / 10 | 80.0% |\n';
const encodedReport = Buffer.from(report, 'utf8').toString('base64');

function createFakeGitHub({
  comments = [],
  failure = {}
} = {}) {
  const calls = {
    create: [],
    update: [],
    delete: []
  };
  const listComments = async () => comments;
  const github = {
    paginate: async (method, parameters) => {
      assert.equal(method, listComments);
      assert.deepEqual(parameters, {
        owner: 'example',
        repo: 'pitcrew',
        issue_number: 196,
        per_page: 100
      });
      return comments;
    },
    rest: {
      issues: {
        listComments,
        createComment: async parameters => {
          calls.create.push(parameters);
          if (failure.create) {
            throw failure.create;
          }
        },
        updateComment: async parameters => {
          calls.update.push(parameters);
          if (failure.update) {
            throw failure.update;
          }
        },
        deleteComment: async parameters => {
          calls.delete.push(parameters);
          if (failure.delete) {
            throw failure.delete;
          }
        }
      }
    }
  };

  return { github, calls };
}

test('creates one comment when no marked comment exists', async () => {
  const { github, calls } = createFakeGitHub({
    comments: [{ id: 5, body: 'unrelated' }]
  });

  await upsertCoverageComment({ github, context, encodedReport });

  assert.equal(calls.create.length, 1);
  assert.equal(calls.update.length, 0);
  assert.equal(calls.delete.length, 0);
});

test('updates the existing marked comment', async () => {
  const { github, calls } = createFakeGitHub({
    comments: [{ id: 7, body: `${COMMENT_MARKER}\nold` }]
  });

  await upsertCoverageComment({ github, context, encodedReport });

  assert.equal(calls.create.length, 0);
  assert.deepEqual(calls.update.map(call => call.comment_id), [7]);
  assert.equal(calls.delete.length, 0);
});

test('selects the lowest comment id and removes marked duplicates', async () => {
  const { github, calls } = createFakeGitHub({
    comments: [
      { id: 12, body: `${COMMENT_MARKER}\nnewer` },
      { id: 8, body: 'unrelated' },
      { id: 4, body: `${COMMENT_MARKER}\noldest` },
      { id: 9, body: `${COMMENT_MARKER}\nmiddle` }
    ]
  });

  await upsertCoverageComment({ github, context, encodedReport });

  assert.deepEqual(calls.update.map(call => call.comment_id), [4]);
  assert.deepEqual(calls.delete.map(call => call.comment_id), [9, 12]);
});

test('uses the deterministic marker and exact workflow run URL', async () => {
  const { github, calls } = createFakeGitHub();

  await upsertCoverageComment({ github, context, encodedReport });

  assert.equal(
    calls.create[0].body,
    `${COMMENT_MARKER}\n${report.trimEnd()}\n\n` +
      '[View exact workflow run]' +
      '(https://github.com/example/pitcrew/actions/runs/123456789)\n'
  );
});

test('rejects missing and malformed coverage reports', async () => {
  const { github } = createFakeGitHub();
  const invoke = value => upsertCoverageComment({
    github,
    context,
    encodedReport: value
  });

  await assert.rejects(
    invoke(undefined),
    /produced no coverage report/
  );
  await assert.rejects(
    invoke('not base64'),
    /malformed base64 coverage output/
  );
  await assert.rejects(
    invoke('A'),
    /malformed base64 coverage output/
  );
  await assert.rejects(
    invoke(Buffer.from('  ').toString('base64')),
    /empty coverage report/
  );
  await assert.rejects(
    invoke(Buffer.from([0xff]).toString('base64')),
    /malformed UTF-8 coverage output/
  );
});

for (const operation of ['create', 'update', 'delete']) {
  test(`propagates ${operation} comment failure`, async () => {
    const expected = new Error(`${operation} failed`);
    const comments = operation === 'create'
      ? []
      : operation === 'update'
        ? [{ id: 4, body: COMMENT_MARKER }]
        : [
            { id: 4, body: COMMENT_MARKER },
            { id: 9, body: COMMENT_MARKER }
          ];
    const { github } = createFakeGitHub({
      comments,
      failure: {
        [operation]: expected
      }
    });

    await assert.rejects(
      upsertCoverageComment({ github, context, encodedReport }),
      error => error === expected
    );
  });
}
