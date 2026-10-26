# AGENTS.md

Qualquer agente que mexe neste repo (Claude, GPT, Gemini, Antigravity, Cursor, Copilot, outro) segue as **regras mínimas da org Valebrum**:
https://github.com/Valebrum/ndv-ai-agent/blob/main/REGRAS-MINIMAS.md

Em uma linha: cadastro e login são da intranet; nada de script avulso fora de repo; teste antes do código em lógica de negócio; segredo fora do código, do log e da linha de comando; entregue provado no ar. A PR roda o check `regras`.

**Duas regras que reprovam ou param o trabalho:**
1. **Toda alteração de código nasce de uma tarefa no TaskHub** (https://extranet.grupovalebrum.com/taskhub/): o número da tarefa vai no título ou no branch da PR (ex.: `feat: ... (#12345)`, `feat/12345-...`). PR de agente sem tarefa é recusada pelo check `regras`.
2. **Todo agente que trabalha nos repos da Valebrum precisa estar cadastrado no TaskHub como agente, com um dono (pessoa):** TaskHub > Agente > criar; o dono aprova. Agente sem cadastro: pare e peça ao seu dono para cadastrar.

Regras específicas deste repo: `CLAUDE.md` (quando existir).
