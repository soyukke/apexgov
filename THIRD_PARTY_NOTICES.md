# Third-Party Notices

apexgov is licensed under the MIT License (see [`LICENSE`](LICENSE)).

This repository and its release artifacts do not bundle third-party source
code. This file records the third-party material the project relies on or
acknowledges.

## 1. Zig standard library

Release binaries are statically linked with the Zig standard library, which is
distributed under the MIT License, Copyright (c) Zig contributors.
See <https://github.com/ziglang/zig/blob/master/LICENSE>.

## 2. Compatibility test corpora (not distributed)

apexgov is exercised locally against the public test suites of the open-source
projects listed below. These projects are **not** included in this repository
or in any release artifact; developers clone them separately into a
git-ignored directory. They are named here, and in benchmark tables, only to
identify the inputs that were used.

| Project | License | Copyright notice |
|---|---|---|
| [Nonprofit Success Pack (NPSP)](https://github.com/SalesforceFoundation/NPSP) | BSD-3-Clause | Copyright (c) 2015, Salesforce.org |
| [Action Plans](https://github.com/SalesforceLabs/ActionPlansV4) | BSD-3-Clause | Copyright (c) 2022, salesforce.com, inc. |
| [Apex Recipes](https://github.com/trailheadapps/apex-recipes) | CC0-1.0 | — |
| [LWC Recipes / LWC Recipes OSS](https://github.com/trailheadapps/lwc-recipes) | CC0-1.0 | — |
| [Automation Components](https://github.com/trailheadapps/automation-components) | CC0-1.0 | — |
| [Coral Cloud Resorts](https://github.com/trailheadapps/coral-cloud) | CC0-1.0 | — |
| [Easy Spaces](https://github.com/trailheadapps/easy-spaces-lwc) | CC0-1.0 | — |
| [E-Bikes](https://github.com/trailheadapps/ebikes-lwc) | CC0-1.0 | — |
| [eCars](https://github.com/trailheadapps/ecars) | CC0-1.0 | — |
| [Pure Aloe](https://github.com/trailheadapps/purealoe) | CC0-1.0 | — |
| [Redwoods Insurance](https://github.com/trailheadapps/redwoods-insurance) | CC0-1.0 | — |
| [Visualforce to LWC](https://github.com/trailheadapps/visualforce-to-lwc) | CC0-1.0 | — |
| [Dreamhouse](https://github.com/trailheadapps/dreamhouse-lwc) | Apache-2.0 | see upstream |
| [Apex Trigger Actions Framework](https://github.com/mitchspano/apex-trigger-actions-framework) | Apache-2.0 | Copyright 2024 Google LLC |
| [fflib Apex Common / Sample Code](https://github.com/apex-enterprise-patterns/fflib-apex-common) | BSD-3-Clause | Copyright (c), FinancialForce.com, inc |
| [fflib Apex Mocks](https://github.com/apex-enterprise-patterns/fflib-apex-mocks) | BSD-3-Clause | Copyright (c), FinancialForce.com, inc |
| [fflib Apex Extensions](https://github.com/wimvelzeboer/fflib-apex-extensions) | BSD-3-Clause | Copyright (c) 2021, William Velzeboer |
| [AT4DX](https://github.com/apex-enterprise-patterns/at4dx) | BSD-3-Clause | Copyright (c) 2020, John M. Daniel & John Storey |
| [Force DI](https://github.com/apex-enterprise-patterns/force-di) | BSD-3-Clause | Copyright (c) 2018, Andrew Fawcett |
| [Semantic Versioning](https://github.com/dschach/semantic-versioning) | BSD-3-Clause | Copyright (c) 2023, David Schach |
| [Nebula Logger](https://github.com/jongpie/NebulaLogger) | MIT | Copyright (c) 2018 Jonathan Gillespie |
| [Simple Lightning Components](https://github.com/jongpie/SimpleLightningComponents) | MIT | Copyright (c) 2018 Jonathan Gillespie |
| [Expression](https://github.com/cesarParra/expression) | MIT | Copyright (c) 2023 Cesar Parra |
| [Apex Rest Route](https://github.com/callawaycloud/apex-rest-route) | MIT | Copyright (c) 2020 Charles Jonas |
| [Campaign Member Status](https://github.com/dschach/campaign-member-status) | MIT | Copyright (c) 2022 Sercante LLC; Copyright (c) 2023 X-Squared on Demand |
| [Salesforce Test Factory](https://github.com/dhoechst/Salesforce-Test-Factory) | MIT | Copyright (c) 2015 Daniel Hoechst |
| [Duplicate Handling](https://github.com/dschach/duplicatehandling) | GPL-3.0 | see upstream |
| [Record Types](https://github.com/dschach/record-types) | GPL-3.0 | see upstream |

No code from the GPL-licensed projects above is included in apexgov.

### Short test fragments

Unit tests under `src/` are written as original minimal reproductions of
platform behaviour, and apexgov does not ship the implementations of the
projects above. `tools/check_third_party_overlap.py` compares the tests with
the local corpora and fails when a test shares three or more identical lines
with them. Individual lines can still coincide where they are standard
platform API idioms. To the extent any such line is considered to be derived
from one of the BSD- or MIT-licensed projects, it is used under that project's
license, reproduced below.

#### Nonprofit Success Pack (NPSP) — BSD 3-Clause

```
Copyright (c) 2015, Salesforce.org
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright
  notice, this list of conditions and the following disclaimer.
* Redistributions in binary form must reproduce the above copyright
  notice, this list of conditions and the following disclaimer in the
  documentation and/or other materials provided with the distribution.
* Neither the name of Salesforce.org nor the names of
  its contributors may be used to endorse or promote products derived
  from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```

#### fflib Apex Common, fflib Apex Mocks — BSD 3-Clause

```
Copyright (c), FinancialForce.com, inc
All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
   are permitted provided that the following conditions are met:

- Redistributions of source code must retain the above copyright notice,
    this list of conditions and the following disclaimer.
- Redistributions in binary form must reproduce the above copyright notice,
    this list of conditions and the following disclaimer in the documentation
    and/or other materials provided with the distribution.
- Neither the name of the FinancialForce.com, inc nor the names of its contributors
    may be used to endorse or promote products derived from this software without
    specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL
THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

#### Nebula Logger — MIT

```
MIT License

Copyright (c) 2018 Jonathan Gillespie

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

#### Apex Rest Route — MIT

```
MIT License

Copyright (c) 2020 Charles Jonas

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## 3. Trademarks

apexgov is an independent open-source project. It is not affiliated with,
endorsed by, or sponsored by Salesforce, Inc. or any of the projects listed
above. Salesforce and other Salesforce product and service names are
trademarks of Salesforce, Inc., and are used here only to describe what
apexgov works with. All other names are the property of their respective
owners.
