# Third-party software and names

<sub>[KubeFactory](../README.md) · [All docs](../README.md#-docs-by-topic) · [2.0.0-beta.1 pre-release](https://github.com/DasCondor/kubefactory/releases/tag/v2.0.0-beta.1) · [Known limitations](KNOWN_LIMITATIONS.md)</sub>

## Godot Engine

The KubeFactory executable and the browser demo are built with, and contain,
the Godot Engine (version 4.3), which is distributed under the MIT license:

```text
Copyright (c) 2014-present Godot Engine contributors.
Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:
```

```bash
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

Godot itself includes third-party components (FreeType, mbedTLS, and others)
under their own licenses; the full list is at https://godotengine.org/license.

## Tools KubeFactory runs but does not include

KubeFactory calls `kubectl`, `docker`, `curl` and, optionally, the AWS, Azure
and Google Cloud command-line tools that are already installed on your machine.
None of them is distributed with KubeFactory.

## App lists

`catalogs.json` points at app-template lists published by other people
(Portainer's official templates and community lists). KubeFactory downloads
them at your request and does not include or endorse their contents. Each list
and each container image belongs to its own authors and has its own license.

## Names

KubeFactory is an independent project. It is not affiliated with, sponsored by
or endorsed by any of the following, whose names are used only to say what the
software works with:

- Kubernetes is a registered trademark of The Linux Foundation.
- Portainer is a trademark of Portainer.io. The in-game character "Porter"
  and the "Portainer dock" refer to KubeFactory's optional Portainer integration.
- Docker is a trademark of Docker, Inc.
- Amazon EKS, Azure AKS, Google GKE, Rancher, Grafana Loki and the other
  product names mentioned belong to their respective owners.
