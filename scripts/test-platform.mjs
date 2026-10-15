import assert from 'node:assert/strict';
import {parseRosterCSV,encryptBackup,decryptBackup} from '../js/platform-utils.js';

assert.deepEqual(parseRosterCSV('\uFEFF學號,姓名\r\nD1,"王,小明"\r\nD2,陳同學\r\n'),[
 {student_no:'D1',display_name:'王,小明'},{student_no:'D2',display_name:'陳同學'}
]);
assert.deepEqual(parseRosterCSV('D1,王同學\nD2,"陳\n同學"'),[
 {student_no:'D1',display_name:'王同學'},{student_no:'D2',display_name:'陳\n同學'}
]);
assert.throws(()=>parseRosterCSV('D1,A\nD1,B'),/學號重複/);
assert.throws(()=>parseRosterCSV('D1,A,B'),/格式不正確/);
assert.throws(()=>parseRosterCSV('"bad,D1'),/引號未關閉/);
assert.throws(()=>parseRosterCSV(''),/至少輸入/);
assert.throws(()=>parseRosterCSV('D1,'),/格式不正確/);
assert.throws(()=>parseRosterCSV(Array.from({length:201},(_,i)=>'D'+i+',A').join('\n')),/200/);

const backup={format:'classpoll-room-backup-v1',room:{code:'E2ETEST',title:'Class'},
 students:[{student_no:'Q01',display_name:'A'}],questions:[],answers:[]};
const key='this-is-a-long-unique-passphrase';
const ciphertext=await encryptBackup(backup,key);
assert.equal(ciphertext.format,'classpoll-encrypted-v1');
assert.equal(ciphertext.algorithm,'AES-256-GCM');
assert.equal(ciphertext.iterations,310000);
assert(!JSON.stringify(ciphertext).includes('Q01'),'Encryption must not leak student IDs as plaintext');
assert.deepEqual(await decryptBackup(ciphertext,key),backup);
await assert.rejects(decryptBackup(ciphertext,'incorrect-long-passphrase'),/解密失敗/);
const tampered={...ciphertext,payload:'AAAA'+ciphertext.payload.slice(4)};
await assert.rejects(decryptBackup(tampered,key),/解密失敗/);
await assert.rejects(encryptBackup(backup,'short'),/12/);
console.log('Platform tests passed: CSV quoting/validation and encrypted backup roundtrip/tampering.');
