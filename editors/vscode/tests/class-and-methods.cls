// SYNTAX TEST "source.apex"

public with sharing class RecordPage {
// <-- storage.modifier.apex
//     ^^^^ storage.modifier.apex
//          ^^^^^^^ storage.modifier.apex
//                  ^^^^^ keyword.declaration.apex
//                        ^^^^^^^^^^ entity.name.type.apex

    private List<String> records;
//  ^^^^^^^ storage.modifier.apex
//          ^^^^ support.type.apex
//               ^^^^^^ support.type.apex

    private Integer totalRecordCount;
//  ^^^^^^^ storage.modifier.apex
//          ^^^^^^^ support.type.apex

    public List<String> getRecords() {
//  ^^^^^^ storage.modifier.apex
//         ^^^^ entity.name.type.apex
//              ^^^^^^ support.type.apex
//                      ^^^^^^^^^^ entity.name.function.apex

        return this.records;
//      ^^^^^^ keyword.control.apex
//             ^^^^ keyword.other.apex
    }
}
