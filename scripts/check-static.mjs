import fs from 'node:fs';
import path from 'node:path';

let checks = 0;
function assert(condition, message) {
  checks++;
  if (!condition) throw new Error(message);
}
const read = (file) => fs.readFileSync(file, 'utf8');
const present = (file) => fs.existsSync(file) && fs.statSync(file).isFile();
const required = [
  'index.html', 'teacher.html', 'student.html', 'ballots.html', 'vote.html',
  'js/config.js', 'js/common.js', 'js/teacher.js', 'js/student.js', 'js/ballots.js', 'js/vote.js',
  'assets/style.css', 'assets/ballots.css', 'supabase/01_install.sql', 'supabase/07_governance_ballots.sql',
  'supabase/02_grant_teacher.sql', 'supabase/03_fix_rooms_rls.sql',
  'supabase/04_performance_indexes.sql',
  'supabase/05_fix_vote_deadline.sql', 'supabase/08_ballot_draft_update.sql'
];
for (const file of required) assert(present(file), 'Missing required file: ' + file);
for (const pageName of ['index', 'teacher', 'student', 'ballots', 'vote']) {
  const html = read(pageName + '.html');
  const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map(match => match[1]);
  assert(new Set(ids).size === ids.length, 'Duplicate HTML id in ' + pageName);
  for (const match of html.matchAll(/(?:src|href)="([^"]+)"/g)) {
    const url = match[1];
    if (/^(?:https?:|mailto:|#|data:)/.test(url)) continue;
    assert(present(url.split('?')[0]), pageName + '.html references missing ' + url);
  }
  assert(html.includes('charset="utf-8"'), 'Missing UTF-8 in ' + pageName);
}
for (const pageName of ['teacher', 'student', 'ballots', 'vote']) {
  const html = read(pageName + '.html');
  const script = read('js/' + pageName + '.js');
  const common = read('js/common.js');
  const ids = new Set([...html.matchAll(/\bid="([^"]+)"/g)].map(match => match[1]));
  for (const file of [script, common]) {
    for (const match of file.matchAll(/\$\(['"]([A-Za-z0-9_-]+)['"]\)/g)) {
      assert(ids.has(match[1]), pageName + '.html missing element id: ' + match[1]);
    }
  }
  assert(html.includes('src="js/' + pageName + '.js"'), 'Missing module in ' + pageName);
  assert(html.includes('@supabase/supabase-js@2'), 'Missing Supabase SDK in ' + pageName);
}
for (const name of ['common', 'teacher', 'student', 'ballots', 'vote']) {
  for (const match of read('js/' + name + '.js').matchAll(/from\s+['"](\.[^'"]+)['"]/g)) {
    const filename = path.normalize(path.join('js', match[1]));
    assert(present(filename), 'Unresolved import in ' + name + ': ' + match[1]);
  }
}
const config = read('js/config.js');
const url = config.match(/SUPABASE_URL\s*=\s*['"]([^'"]+)['"]/)?.[1] ?? '';
const key = config.match(/SUPABASE_PUBLISHABLE_KEY\s*=\s*['"]([^'"]+)['"]/)?.[1] ?? '';
assert(/^https:\/\/[a-z0-9.-]+\/?$/.test(url) && !url.includes('YOUR-PROJECT'),
  'Supabase URL must be a project origin, not /rest/v1/');
assert(/^sb_publishable_[A-Za-z0-9_-]{20,}$/.test(key),
  'Only a real configured publishable key is allowed in frontend');
const uncommented = config.replace(/\/\*[\s\S]*?\*\//g, '');
assert(!/sb_secret_|service_role/i.test(uncommented),
  'Private Supabase credentials must not appear in frontend config');
const schema = read('supabase/01_install.sql');
assert(schema.includes('create policy cp2_rooms_read'), 'Room read RLS is required');
assert(/owner_id\s*=\s*\(select auth\.uid\(\)\)/i.test(schema),
  'Room read RLS must use row owner_id directly');
assert(schema.includes('clock_timestamp()>=v_q.ends_at'),
  'Vote cutoff must use wall-clock time, not transaction timestamp');
assert(schema.includes('cp2_vote') && schema.includes('cp2_join'),
  'Student membership and vote RPCs are required');
console.log('ClassPoll static checks passed: ' + checks + ' assertions.');

const governance = read('supabase/07_governance_ballots.sql');
assert(governance.includes('ENABLE ROW LEVEL SECURITY'), 'Governance tables must enable RLS');
assert(governance.includes('PRIMARY KEY(ballot_id,student_id)'), 'Ballot participation requires one vote per voter');
assert(governance.includes('FOR SHARE'), 'Ballot casting must coordinate concurrent closure');
assert(governance.includes('clock_timestamp()'), 'Ballot time must be server enforced');
assert(governance.includes('REVOKE ALL ON TABLE'), 'Ballot internals must not be directly accessible');
assert(governance.includes('min_report_votes'), 'Privacy threshold required');
assert(governance.includes('v_n<v_b.min_report_votes'), 'Activation must reject impossible reporting thresholds');
assert(read('supabase/08_ballot_draft_update.sql').includes("v_b.status<>'draft'"), 'Activated ballot choices must remain immutable');
console.log('ClassPoll ballot policy static checks passed.');
