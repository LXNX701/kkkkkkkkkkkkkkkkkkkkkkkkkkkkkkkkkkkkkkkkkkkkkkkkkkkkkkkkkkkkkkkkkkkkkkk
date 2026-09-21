PATCH VAULT INPUT

Esta pasta nao e copiada para a IPA.
O workflow gera ThreeOneOSFive/Generated/patchvault.bin e remove os .3105 crus da copia temporaria antes do build.

ARQUIVOS DAS OPCOES DE ANTENA

 ALTO + PESCOCO
- sem: hs-alto-neck-sem-antena.3105
- com: hs-alto-neck-com-antena.3105

 ALTO
- apenas com fica habilitado no popup
- com: hs-alto.3105

 PESCOCO
- sem permanece configurado, mas fica desabilitado no popup
- com: hs-neck-com-antena.3105
- sem: hs-neck-sem-antena.3105

 PEITO
- apenas com fica habilitado no popup
- com: hs-peito.3105

As senhas ficam no enum PatchSlots em ThreeOneOSFive/ContentView.swift.
"0" = patch sem senha.

FLUXO NA INTERFACE
1. Ao ligar um HS configurado com antena, o app abre o alerta central "Ativar antena?".
2. HS ALTO + PESCOCO permite escolher sem ou com.
3. HS ALTO, HS PESCOCO e HS PEITO mostram sem apagado/desabilitado e permitem apenas com.
4. Depois da escolha, INJETAR usa a variante selecionada.
5. LOBBY restaura o backup da variante aplicada.
6. Depois de restaurar com sucesso aparece "Desinjetado com sucesso!".

REGRAS DE SELECAO
- Apenas um HS pode ficar selecionado por vez.
- Ao escolher outro HS, o anterior e desligado; se ja estiver aplicado, o backup e restaurado primeiro.
- AIM BOT + ESP 4 DEDOS pode ser usado junto de um unico HS.
- HOLOGRAMA GUNS pode ser usado junto de um unico HS.
- AIM BOT + ESP 4 DEDOS e HOLOGRAMA GUNS nao podem ficar ligados juntos.
- MAGIC BULLET e 120/144 FPS permanecem desabilitados na interface.
