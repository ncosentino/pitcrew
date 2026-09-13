const { TextDecoder } = require('node:util');

const COMMENT_MARKER = '<!-- pitcrew-go-coverage -->';

function decodeCoverageReport(encodedReport) {
  if (typeof encodedReport !== 'string' || encodedReport.length === 0) {
    throw new Error('The contracts job produced no coverage report.');
  }

  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(encodedReport)) {
    throw new Error(
      'The contracts job produced malformed base64 coverage output.');
  }

  const reportBytes = Buffer.from(encodedReport, 'base64');
  const roundTrip = reportBytes.toString('base64').replace(/=+$/, '');
  if (roundTrip !== encodedReport.replace(/=+$/, '')) {
    throw new Error(
      'The contracts job produced malformed base64 coverage output.');
  }

  let report;
  try {
    report = new TextDecoder('utf-8', { fatal: true }).decode(reportBytes);
  } catch {
    throw new Error(
      'The contracts job produced malformed UTF-8 coverage output.');
  }

  if (report.trim().length === 0) {
    throw new Error('The contracts job produced an empty coverage report.');
  }

  return report;
}

async function upsertCoverageComment({
  github,
  context,
  encodedReport
}) {
  const report = decodeCoverageReport(encodedReport);
  const runUrl =
    `${context.serverUrl}/${context.repo.owner}/${context.repo.repo}` +
    `/actions/runs/${context.runId}`;
  const body =
    `${COMMENT_MARKER}\n${report.trimEnd()}` +
    `\n\n[View exact workflow run](${runUrl})\n`;
  const comments = await github.paginate(
    github.rest.issues.listComments,
    {
      owner: context.repo.owner,
      repo: context.repo.repo,
      issue_number: context.issue.number,
      per_page: 100
    }
  );
  const existing = comments
    .filter(comment => comment.body?.includes(COMMENT_MARKER))
    .sort((left, right) => left.id - right.id);

  if (existing.length === 0) {
    await github.rest.issues.createComment({
      owner: context.repo.owner,
      repo: context.repo.repo,
      issue_number: context.issue.number,
      body
    });
    return;
  }

  await github.rest.issues.updateComment({
    owner: context.repo.owner,
    repo: context.repo.repo,
    comment_id: existing[0].id,
    body
  });
  for (const duplicate of existing.slice(1)) {
    await github.rest.issues.deleteComment({
      owner: context.repo.owner,
      repo: context.repo.repo,
      comment_id: duplicate.id
    });
  }
}

module.exports = {
  COMMENT_MARKER,
  decodeCoverageReport,
  upsertCoverageComment
};
