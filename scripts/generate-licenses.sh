#!/bin/bash
# Generates licenses.json for third-party license attribution.
# Run from the repo root: ./scripts/generate-licenses.sh
#
# Requires: cargo, python3 (system)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT="$REPO_ROOT/ConjureDSPExtension/Resources/licenses.json"

echo "Generating third-party license attribution..."

cd "$REPO_ROOT/rust"

# Use cargo metadata + python to extract all crate licenses with license file text
cargo metadata --format-version 1 2>/dev/null | python3 -c "
import json, sys, os, glob

meta = json.load(sys.stdin)

# Get workspace member IDs to exclude our own crates
ws_members = set(meta.get('workspace_members', []))

# Find the cargo registry source directory
registry_src = os.path.expanduser('~/.cargo/registry/src')
registry_dirs = glob.glob(os.path.join(registry_src, 'index.crates.io-*'))
registry_dir = registry_dirs[0] if registry_dirs else ''

def find_license_text(name, version):
    \"\"\"Try to find the license file text for a crate.\"\"\"
    crate_dir = os.path.join(registry_dir, f'{name}-{version}')
    if not os.path.isdir(crate_dir):
        return None

    # Common license file names
    candidates = [
        'LICENSE', 'LICENSE.md', 'LICENSE.txt',
        'LICENSE-MIT', 'LICENSE-MIT.md', 'LICENSE-MIT.txt',
        'LICENSE-APACHE', 'LICENSE-APACHE.md', 'LICENSE-APACHE.txt',
        'LICENCE', 'LICENCE.md', 'LICENCE.txt',
        'COPYING', 'COPYING.md', 'COPYING.txt',
    ]

    texts = []
    found_files = set()
    for candidate in candidates:
        path = os.path.join(crate_dir, candidate)
        if os.path.isfile(path) and candidate not in found_files:
            found_files.add(candidate)
            try:
                with open(path, 'r', errors='replace') as f:
                    text = f.read().strip()
                    if text:
                        texts.append(text)
            except:
                pass

    return '\n\n---\n\n'.join(texts) if texts else None

# Collect all packages
rust_crates = []
for pkg in meta['packages']:
    if pkg['id'] in ws_members:
        continue
    license_text = find_license_text(pkg['name'], pkg['version'])
    entry = {
        'name': pkg['name'],
        'version': pkg['version'],
        'license': pkg.get('license', 'Unknown'),
    }
    if license_text:
        entry['text'] = license_text
    rust_crates.append(entry)

rust_crates.sort(key=lambda p: p['name'].lower())

# Build full output with all categories
output = {
    'categories': [
        {
            'name': 'Swift Packages',
            'entries': [
                {
                    'name': 'Sentry',
                    'version': '9.8.0',
                    'license': 'MIT',
                    'url': 'https://github.com/getsentry/sentry-cocoa',
                    'text': 'MIT License\n\nCopyright (c) 2015 Sentry\n\nPermission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the \"Software\"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:\n\nThe above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.\n\nTHE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.'
                },
                {
                    'name': 'Mixpanel',
                    'version': '4.4.0',
                    'license': 'Apache-2.0',
                    'url': 'https://github.com/mixpanel/mixpanel-swift',
                    'text': 'Licensed under the Apache License, Version 2.0 (the \"License\"); you may not use this file except in compliance with the License. You may obtain a copy of the License at\n\n    http://www.apache.org/licenses/LICENSE-2.0\n\nUnless required by applicable law or agreed to in writing, software distributed under the License is distributed on an \"AS IS\" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.'
                },
                {
                    'name': 'Sparkle',
                    'version': '2.9.0',
                    'license': 'MIT',
                    'url': 'https://github.com/sparkle-project/Sparkle',
                    'text': 'Copyright (c) 2006-2013 Andy Matuschak.\nCopyright (c) 2009-2013 Elgato Systems GmbH.\nCopyright (c) 2011-2014 Kornel Lesinski.\nCopyright (c) 2015-2017 Mayur Pawashe.\nCopyright (c) 2014 C.W. Betts.\nCopyright (c) 2014 Petroules Corporation.\nCopyright (c) 2014 Big Nerd Ranch.\nAll rights reserved.\n\nPermission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the \"Software\"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:\n\nThe above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.\n\nTHE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.'
                }
            ]
        },
        {
            'name': 'JavaScript Libraries',
            'entries': [
                {
                    'name': 'Monaco Editor',
                    'version': '0.52.2',
                    'license': 'MIT',
                    'url': 'https://github.com/microsoft/monaco-editor',
                    'text': 'The MIT License (MIT)\n\nCopyright (c) 2016 - present Microsoft Corporation\n\nPermission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the \"Software\"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:\n\nThe above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.\n\nTHE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.'
                },
                {
                    'name': 'xterm.js',
                    'version': '5.3.0',
                    'license': 'MIT',
                    'url': 'https://github.com/xtermjs/xterm.js',
                    'text': 'The MIT License (MIT)\n\nCopyright (c) 2017-2022, The xterm.js authors (https://github.com/xtermjs/xterm.js)\nCopyright (c) 2014-2016, SourceLair, Private Company (https://www.sourcelair.com)\nCopyright (c) 2012-2013, Christopher Jeffrey (https://github.com/chjj/)\n\nPermission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the \"Software\"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:\n\nThe above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.\n\nTHE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.'
                },
                {
                    'name': '@xterm/addon-fit',
                    'version': '0.11.0',
                    'license': 'MIT',
                    'url': 'https://github.com/xtermjs/xterm.js',
                    'text': 'The MIT License (MIT)\n\nCopyright (c) 2017-2022, The xterm.js authors (https://github.com/xtermjs/xterm.js)\n\nPermission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the \"Software\"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:\n\nThe above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.\n\nTHE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.'
                },
                {
                    'name': '@xterm/addon-web-links',
                    'version': '0.12.0',
                    'license': 'MIT',
                    'url': 'https://github.com/xtermjs/xterm.js',
                    'text': 'The MIT License (MIT)\n\nCopyright (c) 2017-2022, The xterm.js authors (https://github.com/xtermjs/xterm.js)\n\nPermission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the \"Software\"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:\n\nThe above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.\n\nTHE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.'
                }
            ]
        },
        {
            'name': 'Python Runtime',
            'entries': [
                {
                    'name': 'Python',
                    'version': '3.14.3',
                    'license': 'PSF-2.0',
                    'url': 'https://www.python.org',
                    'text': 'Copyright (c) 2001-2026 Python Software Foundation. All Rights Reserved.\n\nPSF LICENSE AGREEMENT FOR PYTHON\n\n1. This LICENSE AGREEMENT is between the Python Software Foundation (\"PSF\"), and the Individual or Organization (\"Licensee\") accessing and otherwise using Python software in source or binary form and its associated documentation.\n\n2. Subject to the terms and conditions of this License Agreement, PSF hereby grants Licensee a nonexclusive, royalty-free, world-wide license to reproduce, analyze, test, perform and/or display publicly, prepare derivative works, distribute, and otherwise use Python alone or in any derivative version, provided, however, that PSF\\'s License Agreement and PSF\\'s notice of copyright, i.e., \"Copyright (c) 2001-2026 Python Software Foundation; All Rights Reserved\" are retained in Python alone or in any derivative version prepared by Licensee.\n\n3. In the event Licensee prepares a derivative work that is based on or incorporates Python or any part thereof, and wants to make the derivative work available to others as provided herein, then Licensee hereby agrees to include in any such work a brief summary of the changes made to Python.\n\n4. PSF is making Python available to Licensee on an \"AS IS\" basis. PSF MAKES NO REPRESENTATIONS OR WARRANTIES, EXPRESS OR IMPLIED. BY WAY OF EXAMPLE, BUT NOT LIMITATION, PSF MAKES NO AND DISCLAIMS ANY REPRESENTATION OR WARRANTY OF MERCHANTABILITY OR FITNESS FOR ANY PARTICULAR PURPOSE OR THAT THE USE OF PYTHON WILL NOT INFRINGE ANY THIRD PARTY RIGHTS.\n\n5. PSF SHALL NOT BE LIABLE TO LICENSEE OR ANY OTHER USERS OF PYTHON FOR ANY INCIDENTAL, SPECIAL, OR CONSEQUENTIAL DAMAGES OR LOSS AS A RESULT OF MODIFYING, DISTRIBUTING, OR OTHERWISE USING PYTHON, OR ANY DERIVATIVE THEREOF, EVEN IF ADVISED OF THE POSSIBILITY THEREOF.\n\n6. This License Agreement will automatically terminate upon a material breach of its terms and conditions.\n\n7. Nothing in this License Agreement shall be deemed to create any relationship of agency, partnership, or joint venture between PSF and Licensee. This License Agreement does not grant permission to use PSF trademarks or trade name in a trademark sense to endorse or promote products or services of Licensee, or any third party.\n\n8. By copying, installing or otherwise using Python, Licensee agrees to be bound by the terms and conditions of this License Agreement.'
                },
                {
                    'name': 'NumPy',
                    'version': '',
                    'license': 'BSD-3-Clause',
                    'url': 'https://numpy.org',
                    'text': 'Copyright (c) 2005-2026, NumPy Developers.\nAll rights reserved.\n\nRedistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:\n\n1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.\n\n2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.\n\n3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.\n\nTHIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS \"AS IS\" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.'
                },
                {
                    'name': 'SciPy',
                    'version': '',
                    'license': 'BSD-3-Clause',
                    'url': 'https://scipy.org',
                    'text': 'Copyright (c) 2001-2002 Enthought, Inc. 2003-2026, SciPy Developers.\nAll rights reserved.\n\nRedistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:\n\n1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.\n\n2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.\n\n3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.\n\nTHIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS \"AS IS\" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.'
                }
            ]
        },
        {
            'name': 'Rust Compiler',
            'entries': [
                {
                    'name': 'Rust Compiler (rustc)',
                    'version': '1.93.1',
                    'license': 'MIT OR Apache-2.0',
                    'url': 'https://www.rust-lang.org',
                    'text': 'Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the \"Software\"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:\n\nThe above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.\n\nTHE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.'
                }
            ]
        },
        {
            'name': 'Rust Crates',
            'entries': rust_crates
        }
    ]
}

json.dump(output, sys.stdout, indent=2, ensure_ascii=False)
" > "$OUTPUT"

TOTAL=$(python3 -c "import json; d=json.load(open('$OUTPUT')); print(sum(len(c['entries']) for c in d['categories']))")
echo "Generated $OUTPUT with $TOTAL entries"
