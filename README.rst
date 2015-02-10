========
hmod-dub
========

------------
Introduction
------------

``hmod-dub`` is a command-line tool that can be used to generate documentation
for any `dub <http://code.dlang.org>`_ package using `harbored-mod
<https://github.com/kiith-sa/harbored-mod>`_. It is used to generate
documentation available at `ddocs.org <http://ddocs.org>`_.


------------
Requirements
------------

To run, ``hmod-dub`` needs ``hmod`` (`harbored-mod
<https://github.com/kiith-sa/harbored-mod>`_) and ``dub`` to be installed
(available in ``PATH``).


-----
Usage
-----

See the help string::

   -------------------------------------------------------------------------------
   hmod-dub
   Generates DDoc documentation for DUB packages (code.dlang.org) using hmod.
   Copyright (C) 2015 Ferdinand Majerech

   Usage: hmod-dub [OPTIONS] package1 package2
          hmod-dub [OPTIONS] package1:version package2

   Examples:
       hmod-dub dyaml:0.5.0 gfm
           Generate documentation for D:YAML 0.5.0 and the current git (~master)
           version of GFM. The documentation will be written into the './doc'
           directory.

   Options:
       -h, --help                     Show this help message.
       -o, --output-directory DIR     Directory to write generated documentation
                                      into. The documentation for each package
                                      will be written into subdirectories in
                                      format DIR/PACKAGE-NAME/PACKAGE-VERSION .
                                      Default: ./doc
       -p, --process-count COUNT      Maximum number of external processes
                                      hmod-dub should launch. E.g. if 4, hmod-dub
                                      can fetch or generate documentation for 4
                                      packages at the same time.
                                      Default: 2
       -d, --dub-directory DIR        Directory where DUB stores fetched packages.
                                      Default (Linux): ~/.dub/packages
                                      Default (Windows/OSX): TODO
       -t, --process-time-limit SECS  Maximum time in seconds to allow any
                                      external process to run. E.g. if 10,
                                      hmod-dub gives up if fetching a package
                                      takes more than 10 seconds.
                                      Default: 60
       -a, --max-doc-age SECS         Maximum age of pre-existing documentation.
                                      hmod-dub writes '.time' files storing
                                      a timestamp specifying when the
                                      documentation
                                      Default: 604800 (7 days)
       -a, --max-doc-age-branch SECS  Same as maxDocAge, but for branches, not
                                      release versions (e.g. ~master).
                                      Default: 172800 (2 days)
       -r, --max-fetch-retries TIMES  Maximum number of times to retry fetching
                                      a package if we failed to receive data.
                                      Default: 2
       -s, --status-output-path PATH  Path to write a YAML file with info about
                                      documentation generation status (errors,
                                      logs, etc.) for individual packages. If not
                                      specified, this file will not be written.
       -A, --additional-toc-link STR  Can be used more than once to add links
                                      to specified files to the tables of contents
                                      of generated documentation. STR is of format
                                      "name:path" where path points to the current
                                      directory, e.g. "DDocs.org:index.html". Can
                                      be used more than once to add more links.
       -m, --max-file-size KILOBYTES  Maximum module file size for `hmod` to
                                      accept. Any modules bigger than this will be
                                      ignored. Helps avoid huge RAM usage.
                                      Default: 8192 (8MiB)
   -------------------------------------------------------------------------------


-------------------
Directory structure
-------------------

===============  =======================================================================
Directory        Contents
===============  =======================================================================
``./``           This README, license, dub config.
``./source``     Source code.
===============  =======================================================================


-------
License
-------

``hmod-dub`` is released under the terms of the `Boost Software License 1.0
<http://www.boost.org/LICENSE_1_0.txt>`_.  This license allows you to use the source code
in your own projects, open source or proprietary, and to modify it to suit your needs.
However, in source distributions, you have to preserve the license headers in the source
code and the accompanying license file.

Full text of the license can be found in file ``LICENSE_1_0.txt`` and is also
displayed here::

    Boost Software License - Version 1.0 - August 17th, 2003

    Permission is hereby granted, free of charge, to any person or organization
    obtaining a copy of the software and accompanying documentation covered by
    this license (the "Software") to use, reproduce, display, distribute,
    execute, and transmit the Software, and to prepare derivative works of the
    Software, and to permit third-parties to whom the Software is furnished to
    do so, all subject to the following:

    The copyright notices in the Software and this entire statement, including
    the above license grant, this restriction and the following disclaimer,
    must be included in all copies of the Software, in whole or in part, and
    all derivative works of the Software, unless such copies or derivative
    works are solely in the form of machine-executable object code generated by
    a source language processor.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT
    SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE
    FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE,
    ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
    DEALINGS IN THE SOFTWARE.


-------
Credits
-------

``hmod-dub`` was created by Ferdinand Majerech aka Kiith-Sa kiithsacmp[AT]gmail.com,
using Vim and DMD on Linux Mint.

See more `D <http://www.dlang.org>`_ projects at `code.dlang.org
<http://code.dlang.org>`_.
