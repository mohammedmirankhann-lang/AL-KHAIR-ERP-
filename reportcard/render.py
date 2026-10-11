from playwright.sync_api import sync_playwright
import os
with sync_playwright() as p:
    b=p.chromium.launch(executable_path='/opt/pw-browsers/chromium') if os.path.exists('/opt/pw-browsers/chromium') else p.chromium.launch()
    pg=b.new_page(); pg.goto('file://'+os.path.abspath('sample.html')); pg.pdf(path='AlKhair_ReportCard_SAMPLE.pdf',format='A4',print_background=True,prefer_css_page_size=True); b.close()
