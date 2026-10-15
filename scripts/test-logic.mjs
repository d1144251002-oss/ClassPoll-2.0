import assert from 'node:assert/strict';
import {taipeiToday,activeParticipation,escapeHtml,asOptions} from '../js/common.js';

// Database attendance dates use Asia/Taipei (UTC+08:00), not browser timezone.
assert.equal(taipeiToday(new Date('2026-10-15T15:59:59.000Z')),'2026-10-15');
assert.equal(taipeiToday(new Date('2026-10-15T16:00:00.000Z')),'2026-10-16');
assert.equal(taipeiToday(new Date('2026-12-31T16:00:00.000Z')),'2027-01-01');

const active=[{id:'one',is_active:true},{id:'two',is_active:true},{id:'disabled',is_active:false}];
assert.deepEqual(activeParticipation(active,[]),{count:0,total:2,percent:0});
assert.deepEqual(activeParticipation(active,[{student_id:'one'}]),{count:1,total:2,percent:50});
assert.deepEqual(activeParticipation(active,[{student_id:'one'},{student_id:'disabled'}]),
  {count:1,total:2,percent:50});
assert.deepEqual(activeParticipation([{id:'disabled',is_active:false}],[{student_id:'disabled'}]),
  {count:0,total:0,percent:null});

assert.equal(escapeHtml('<script>"&\'</script>'),'&lt;script&gt;&quot;&amp;&#39;&lt;/script&gt;');
assert.deepEqual(asOptions('["A","B"]'),['A','B']);
console.log('ClassPoll behavior tests passed: Taiwan date, participation, output escaping.');
