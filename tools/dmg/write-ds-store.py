"""dmg のウィンドウの表示設定（.DS_Store）を書く（PLAN §11.3 の 3・F-99）。

make-dmg.sh が、dist/ の中にマウントした作業用のイメージ（/Volumes の外）に対して呼ぶ。Finder は使わない。
大きさと位置は tools/dmg/make-background.swift の背景画像と同じ値。

使い方: write-ds-store.py <マウント先> <アプリの名前（VoiceDock.app）> <背景画像の相対パス（.background/background.tiff）>
"""
import os
import sys

from ds_store import DSStore
from mac_alias import Alias

WINDOW = (660, 400)  # 背景画像と同じ pt
ORIGIN = (200, 120)  # 画面の左上からの位置
ICON_SIZE = 128
APP_POSITION = (170, 190)  # アイコンの中心
APPLICATIONS_POSITION = (490, 190)


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    mount, app_name, background = sys.argv[1:]
    background_path = os.path.join(mount, background)
    if not os.path.isfile(background_path):
        print(f"ERROR: 背景画像がありません: {background_path}", file=sys.stderr)
        return 1
    alias = Alias.for_file(background_path).to_bytes()
    x, y = ORIGIN
    width, height = WINDOW
    with DSStore.open(os.path.join(mount, ".DS_Store"), "w+") as store:
        store["."]["bwsp"] = {
            "WindowBounds": f"{{{{{x}, {y}}}, {{{width}, {height}}}}}",
            "ShowToolbar": False,
            "ShowStatusBar": False,
            "ShowPathbar": False,
            "ShowSidebar": False,
            "ShowTabView": False,
            "ContainerShowSidebar": False,
            "SidebarWidth": 0,
        }
        store["."]["icvp"] = {
            "viewOptionsVersion": 1,
            "backgroundType": 2,  # 画像
            "backgroundImageAlias": alias,
            "backgroundColorRed": 1.0,
            "backgroundColorGreen": 1.0,
            "backgroundColorBlue": 1.0,
            "iconSize": float(ICON_SIZE),
            "textSize": 13.0,
            "gridSpacing": 100.0,
            "gridOffsetX": 0.0,
            "gridOffsetY": 0.0,
            "labelOnBottom": True,
            "showIconPreview": False,
            "showItemInfo": False,
            "arrangeBy": "none",
        }
        store["."]["vSrn"] = ("long", 1)
        store[app_name]["Iloc"] = APP_POSITION
        store["Applications"]["Iloc"] = APPLICATIONS_POSITION
    print(f"OK: {os.path.join(mount, '.DS_Store')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
