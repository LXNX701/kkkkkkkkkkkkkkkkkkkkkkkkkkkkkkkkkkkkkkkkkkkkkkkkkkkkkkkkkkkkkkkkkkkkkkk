PATCHES

Coloque seus arquivos .3105 nesta pasta.

O workflow deve copiá-los para:
Payload/3105.app/Patches/

ContentView.swift > PatchSlots:
- o nome precisa ser exatamente igual ao arquivo
- password = "0" significa sem senha
- se houver senha, coloque-a entre aspas

Exemplo:
static let hsAltoNeck = "hs-alto-neck.3105"
static let hsAltoNeckPassword = "0"
