// SYNTAX TEST "source.apex"

// Line comment
// <--- comment.line.double-slash.apex

/* Block comment */
// <--- comment.block.apex

'hello world'
// <--- string.quoted.single.apex

'escaped \' quote'
// <--- string.quoted.single.apex

123
// <-- constant.numeric.integer.apex

3.14
// <-- constant.numeric.decimal.apex

0xFF
// <-- constant.numeric.hex.apex

true
// <-- constant.language.apex

false
// <-- constant.language.apex

null
// <-- constant.language.apex

@isTest
// <----- storage.type.annotation.apex

@AuraEnabled
// <----------- storage.type.annotation.apex
