// SYNTAX TEST "source.apex"

[SELECT Id, Name FROM Account WHERE Name = 'test' LIMIT 10]
// <--- keyword.other.soql.apex
//      ^^ entity.name.type.apex
//              ^^^^ keyword.other.soql.apex
//                   ^^^^^^^ entity.name.type.apex
//                           ^^^^^ keyword.other.soql.apex
//                                         ^^^^^^ string.quoted.single.soql.apex
//                                                ^^^^^ keyword.other.soql.apex
