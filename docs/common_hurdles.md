# Common hurdles

This page will document all common hurdles you may expiriance while developing or using nim-libp2p.

## compile error: undeclared identifier

Sometimes compiling nim-libp2p or your project that deepnds on nim-libp2p may produce following commpile error:

```
nim c -r --threads:on libp2p_chat_example.nim
Hint: used config file '/home/user/.choosenim/toolchains/nim-2.2.0/config/nim.cfg' [Conf]
Hint: used config file '/home/user/.choosenim/toolchains/nim-2.2.0/config/config.nims' [Conf]
.......................................................................................................................................................................
/home/user/.nimble/pkgs2/libp2p-1.14.3-3c089f3ccd23aa5a04e5db288cb8eef524938487/libp2p/utility.nim(77, 30) Error: undeclared identifier: 'Opt'
```

Error message `Error: undeclared identifier:` can complain about indentifer of any other library - it will be different from time to time. Root cause is the same for all error of this kind.

To fix this please, follow these steps:

1) remove `/home/user/.nimble` - to remove everything (nim & nimble)
2) install nim again - fresh install
3) `nimble install nimble`  - get latest `nimble` first
4) then install libp2p



---

(open a pull request if you want something to be included here)