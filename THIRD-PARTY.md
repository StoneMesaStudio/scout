# Third-party code in Scout

Scout is GPL-3.0-or-later. It ships one piece of code it did not write.

## Sparkle

<https://sparkle-project.org> — the update framework. It is what checks the website for a newer
Scout and installs one. MIT licensed, which is compatible in this direction: MIT code may be
included in a GPL work, and the combined work is distributed under the GPL.

Sparkle carries a few components under their own permissive licences: bsdiff (BSD 2-clause),
sais-lite (MIT), an ed25519 implementation (Zlib), and a signature verifier (BSD 2-clause). The
full text of all of them is inside the framework, at
`Scout.app/Contents/Frameworks/Sparkle.framework/Resources/`.

    Copyright (c) 2006-2013 Andy Matuschak
    Copyright (c) 2009-2013 Elgato Systems GmbH
    Copyright (c) 2011-2014 Kornel Lesiński
    Copyright (c) 2015-2017 Mayur Pawashe
    Copyright (c) 2014 C.W. Betts
    Copyright (c) 2014 Petroules Corporation
    Copyright (c) 2014 Big Nerd Ranch

    Permission is hereby granted, free of charge, to any person obtaining a copy of this software
    and associated documentation files (the "Software"), to deal in the Software without
    restriction, including without limitation the rights to use, copy, modify, merge, publish,
    distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
    Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or
    substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
    BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
    NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
    DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## The signing key

Updates are signed with an EdDSA key that is not the Apple one. The private half lives in the
login Keychain on the Mac that makes releases, as **"Private key for signing Sparkle updates"**;
the public half is `SUPublicEDKey` in the app's Info.plist, and every copy of Scout already out
there checks against it.

**It cannot be replaced without abandoning everyone already running Scout.** A new key means every
existing copy refuses every future update, and each person has to notice and download the app
again by hand. Export a copy and keep it somewhere safe:

    ./bin/generate_keys -x scout-sparkle-key.txt      # writes the private key to a file
    ./bin/generate_keys -f scout-sparkle-key.txt      # puts it back, on a new Mac
