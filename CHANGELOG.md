# Changelog
All notable changes to this project will be documented in this file. See [conventional commits](https://www.conventionalcommits.org/) for commit guidelines.

- - -

#### Features

- add Apple Translation progress - ([647077f](https://github.com/duncanleo/kshowsub-swift/commit/647077fd9f8468e5c3f9c0fe6f95a477d5b90adb)) - Duncan Leo, OpenAI Codex


#### Bug Fixes

- refine OpenAI subtitle translation prompt - ([ba3bdef](https://github.com/duncanleo/kshowsub-swift/commit/ba3bdeff84595c8a3695af61f7471f969a38e1a4)) - Duncan Leo, Codex

- refine positioned OCR collision avoidance - ([cdf5fd8](https://github.com/duncanleo/kshowsub-swift/commit/cdf5fd86690efa202efe5d904ff899bd4c7ae062)) - Duncan Leo, Codex


#### Documentation

- document co-author commit trailer - ([184ec1a](https://github.com/duncanleo/kshowsub-swift/commit/184ec1abf99ed572808a92027bb94154851e4dc6)) - Duncan Leo, OpenAI Codex


#### Miscellaneous Chores

- ignore .env - ([2b02e7b](https://github.com/duncanleo/kshowsub-swift/commit/2b02e7b4a5826ad2fe6825f62b9869ee22eadce3)) - Duncan Leo



- - -


#### Features

- position OCR overlays (#2) - ([d001dc4](https://github.com/duncanleo/kshowsub-swift/commit/d001dc49edf7be2a1e1085439143c65750cff6e8)) - Duncan Leo



- - -


#### Features

- add speech and OCR provider protocols - ([5191089](https://github.com/duncanleo/kshowsub-swift/commit/51910897eb4a5b82e1f8a3a6f3525d28d2856d19)) - Duncan Leo

- add --version flag and wire version into release workflow - ([b78469a](https://github.com/duncanleo/kshowsub-swift/commit/b78469a230100d504f50cb6552236e99a2224936)) - Duncan Leo, Claude Sonnet 4.6

- add apple-translation provider using Translation framework - ([fad85a6](https://github.com/duncanleo/kshowsub-swift/commit/fad85a69b32ed631e0252173210058486d5bc400)) - Duncan Leo, Claude Sonnet 4.6

- translation support with OpenAI API - ([2477990](https://github.com/duncanleo/kshowsub-swift/commit/24779902cede040b5684e3ab3d523f50667a9ffd)) - Duncan Leo

- initial translation support with Apple Foundation Models - ([d8997ca](https://github.com/duncanleo/kshowsub-swift/commit/d8997ca9d851c9f3a4061c8fad44b851bb64021e)) - Duncan Leo

- functional OCR + speech transcription - ([67eac8f](https://github.com/duncanleo/kshowsub-swift/commit/67eac8f55b227886ae7627475b41c234cdb25e29)) - Duncan Leo


#### Bug Fixes

- (**cog**) emit explicit changelog links - ([839adf0](https://github.com/duncanleo/kshowsub-swift/commit/839adf0c2a526cbc0b2083322df35f91bcfca270)) - Duncan Leo

- create `.swift-version` - ([a7e6ec1](https://github.com/duncanleo/kshowsub-swift/commit/a7e6ec192803fbe7c82557fbab50727f5206c027)) - Duncan Leo

- (**cog**) Set changelog template to full hash - ([6b0257c](https://github.com/duncanleo/kshowsub-swift/commit/6b0257c5176550a580f1a8cbbcd110971aa7f69f)) - Duncan Leo


#### Documentation

- mandate conventional commits - ([c567a58](https://github.com/duncanleo/kshowsub-swift/commit/c567a58dd8f694e4163c2c4804e2dad69a5742ff)) - Duncan Leo

- document apple-translation provider in README - ([29547ab](https://github.com/duncanleo/kshowsub-swift/commit/29547abc98191bf0ec664de8e0b2b146f976d3af)) - Duncan Leo, Claude Sonnet 4.6

- add README - ([e16c502](https://github.com/duncanleo/kshowsub-swift/commit/e16c502585f5c10d4d367c6bc5b95c0168a47fa6)) - Duncan Leo


#### Tests

- add validation runner and harness docs - ([52fc99f](https://github.com/duncanleo/kshowsub-swift/commit/52fc99f020a1dfef414d8d0dabdcbcf78cabcd99)) - Duncan Leo


#### Build system

- enable KShowSubCore debug testing - ([2656492](https://github.com/duncanleo/kshowsub-swift/commit/26564925a5b39ab5b869e883931d38ff0fc7486a)) - Duncan Leo

- (**ci**) add release workflow - ([aea609a](https://github.com/duncanleo/kshowsub-swift/commit/aea609a34f9f5aa728f98f618fb3f4f1902c7dc6)) - Duncan Leo

- (**deps**) add 'swift-subtitle-kit' - ([6b6ad1c](https://github.com/duncanleo/kshowsub-swift/commit/6b6ad1c64ad443fc8446c5e6d2a54d0864dc11e0)) - Duncan Leo

- (**deps**) add 'swift-argument-parser' - ([69ae4f0](https://github.com/duncanleo/kshowsub-swift/commit/69ae4f0c08db58dfdabc7136fdc47cd5476e141e)) - Duncan Leo


#### Continuous Integration

- Guard release bump behind successful build - ([28064f3](https://github.com/duncanleo/kshowsub-swift/commit/28064f36cbb8a289b24a355ecc6cd7e79495c27b)) - Duncan Leo

- build release product only - ([cb969d1](https://github.com/duncanleo/kshowsub-swift/commit/cb969d1599a1039a826812880d12ab3bd6352184)) - Duncan Leo

- fix release changelog generation - ([d08ccbe](https://github.com/duncanleo/kshowsub-swift/commit/d08ccbeaf3857c0ca3cd535ae971ba76d1ee7d7f)) - Duncan Leo


#### Refactoring

- replace OCR print() calls with os Logger - ([81c216e](https://github.com/duncanleo/kshowsub-swift/commit/81c216e9c970ce1f8291b1ce1a964a4575ad3588)) - Duncan Leo, Claude Sonnet 4.6


#### Miscellaneous Chores

- add cocogitto cog.toml config - ([e7b1865](https://github.com/duncanleo/kshowsub-swift/commit/e7b186597131c5c955a8b31e87dbc8f75bd407dd)) - Duncan Leo

- add MIT License file - ([8f7593e](https://github.com/duncanleo/kshowsub-swift/commit/8f7593e7294d7039bd6daaf0659b33ff86c8ea98)) - Duncan Leo

- initial command scaffold - ([cb7bc9b](https://github.com/duncanleo/kshowsub-swift/commit/cb7bc9b51fb915587792c055c7cf18ef1a99e307)) - Duncan Leo

- initial commit - ([e76051e](https://github.com/duncanleo/kshowsub-swift/commit/e76051e164141ef3887c52b8e4fc2339d6346347)) - Duncan Leo



- - -

Changelog generated by [cocogitto](https://github.com/cocogitto/cocogitto).