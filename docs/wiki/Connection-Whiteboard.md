# Connection whiteboard

The whiteboard draws every app, volume and outside endpoint of a demo world as
a diagram, with every route between them. Open it from the game menu
(**Connection whiteboard**, or **Whiteboard** on phones) or from **Network and
shared data**. Demo data is SIMULATED.

![The whiteboard in every demo world: Kubernetes cluster, Home Assistant, Dev containers, Media suite, Docker media lab and the lab with its gatherer, each with its busiest tile selected, then a closer look and the same board in 2D](media/board-tour.gif)

The tour visits every demo world's whiteboard: Kubernetes cluster, Home
Assistant, Dev containers, Media suite, Docker media lab, and the Docker media
lab with its gatherer. [Watch it as an MP4](media/board-tour.mp4).

## Views

| View | What it shows |
| --- | --- |
| **Isometric** (default) | Grid paper with a rounded tile per endpoint, its app icon and name, and lines along the grid with arrowheads. A dot moves along a route while it carries traffic. |
| **2D** | The same board from straight above, with the same layout and selection. |
| **Cards** | The card board, with each endpoint's ports listed on its card. |

Select a tile to lift it and fade everything unrelated. Each of its routes gets
a callout saying what it carries: HTTPS, Metrics, Storage mount, LAN · down.
Double-click or double-tap a tile to open its config and storage files.

## Controls

| | Mouse | Touch |
| --- | --- | --- |
| Pan | drag the paper | drag the paper |
| Zoom | wheel, or **+** / **-** | pinch |
| Select | click | tap |
| Open files | double-click | double-tap |
| Move a tile | drag it | select it, then drag it |

**Fit board** shows the whole board. On a phone it stops at a readable tile
size and you drag to see the rest. **Save whiteboard** keeps your layout on
this device, and the board table in the factory uses it too.

## Re-recording this page's media

`powershell -ExecutionPolicy Bypass -File tools\record-tour.ps1 board` records
the tour again and replaces `media/board-tour.mp4` and `media/board-tour.gif`.
