// SYNTAX TEST "source.apex"

if (true) {
// <-- keyword.control.apex

} else {
// <-- keyword.control.apex

for (Integer i = 0; i < 10; i++) {
//  <-- keyword.control.apex
//   ^^^^^^^ support.type.apex

while (running) {
// <-- keyword.control.apex

try {
// <-- keyword.control.apex

} catch (Exception e) {
// <--- keyword.control.apex
//       ^^^^^^^^^ entity.name.type.apex

} finally {
// <----- keyword.control.apex

    throw new Exception('error');
//  ^^^^^ keyword.control.apex
//        ^^^ keyword.other.apex
//            ^^^^^^^^^ entity.name.type.apex

insert accounts;
// <-- keyword.other.dml.apex

update contacts;
// <-- keyword.other.dml.apex

delete records;
// <-- keyword.other.dml.apex

upsert leads;
// <-- keyword.other.dml.apex
