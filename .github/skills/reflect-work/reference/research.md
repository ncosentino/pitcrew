# Research behind the procedure

These sources motivate the design; none establishes this combined skill's
effectiveness in a consumer repository. Do not treat a vendor case study, a documented
capability, and a controlled experiment as interchangeable evidence.

| Source | Relevant contribution | Boundary |
| --- | --- | --- |
| [Anthropic: writing tools for agents](https://www.anthropic.com/engineering/writing-tools-for-agents) | Transcript/error/cost analysis followed by held-out task evaluation | Agent explanations can miss or misattribute failures |
| [Anthropic: agent evaluations](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents) | Actual outcomes, isolated trials, positive/negative cases, calibrated graders | A grader or environment can itself be wrong |
| [Anthropic: Agent Skills](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills) | Progressive disclosure and executable helpers | Discovery and activation need evaluation |
| [OpenAI: harness engineering](https://openai.com/index/harness-engineering/) | Small root map, repository knowledge and mechanical checks | Internal operational case study, not universal workflow proof |
| [OpenAI: evaluation flywheel](https://developers.openai.com/cookbook/examples/evaluation/building_resilient_prompts_using_an_evaluation_flywheel) | Analyze, measure and improve with calibrated judging | Its worked domain and thresholds do not transfer automatically |
| [Microsoft: Agent Lightning](https://arxiv.org/abs/2508.03680) | Separation of execution, trajectories, rewards and optimization | Primarily model training, not instruction maintenance |
| [Microsoft: EvoLib](https://arxiv.org/abs/2605.14477) | Consolidation and utility-informed retrieval of skills/insights | Assumes sufficiently reliable self-scoring; de-emphasis is not deletion |
| [AGENTS.md evaluation](https://arxiv.org/abs/2602.11988v2) | Instruction adherence and extra exploration need not improve task outcomes | Results describe the evaluated context files/models, not every instruction |
| [Self-correction survey](https://arxiv.org/html/2406.01297v3) | Importance of external feedback and strong comparison baselines | Primarily surveys work through May 2024 |

Source-inspected implementation examples:

- [Compound Engineering capture](https://github.com/EveryInc/compound-engineering-plugin/blob/082c83e0537c803ac1d927daafc2e6eb6962dedf/skills/ce-compound/SKILL.md):
  durable verified knowledge, explicit no-change and consolidation; some maintenance
  permissions are broader than this skill's report-only boundary.
- [claude-reflect skill proposals](https://github.com/BayramAnnakov/claude-reflect/blob/8dc9db43c9bfaa53b567d63f3f48385bcf3d3084/commands/reflect-skills.md):
  separate capture and approval; file/frontmatter checks do not establish behavior.
- [OpenHands review learning](https://github.com/OpenHands/extensions/blob/6242eacba016bf85009d8e3f5b8aa131295e278c/skills/learn-from-code-review/SKILL.md):
  recurring review patterns and focused skills; comments can be biased or stale.
- [Superpowers skill authoring](https://github.com/obra/superpowers/blob/b36e0829c6d0140e93cfef2ca599b1b07d4a7797/skills/writing-skills/SKILL.md):
  baseline failure and behavioral retesting; compliance is not sufficient outcome proof.
- [GEPA reflective dataset adapter](https://github.com/gepa-ai/gepa/blob/15ee314f9c7d34ec153b809d401f42f55c4dcd76/src/gepa/core/adapter.py):
  trace-informed candidates and evaluation; optimization-set gains need held-out checks.

These mechanisms are described, not copied implementations. Their runtime behavior and
benchmark claims were not independently reproduced for this skill.
