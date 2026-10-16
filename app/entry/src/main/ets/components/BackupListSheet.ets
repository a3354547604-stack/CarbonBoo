/**
 * BackupListSheet —— 备份记录半模态（附录 C §23.7 / 验收 D5-10）。
 * 每条含**时间 + 文件大小**；顶部「清理旧备份」= 保留最近 3 份（LiteralConstants.BACKUP_KEEP）。
 */
import { FileEntry } from '../viewmodel/store/FilesPort';
import { AppTheme } from '../util/AppTheme';
import { Formatter } from '../util/Formatter';
import { EmptyView } from './EmptyView';

@Component
export struct BackupListSheet {
  @Prop entries: FileEntry[] = [];
  @Prop pending: boolean = false;
  onDelete: (path: string) => void = () => {};
  onCleanup: () => void = () => {};
  onClose: () => void = () => {};

  build() {
    Column({ space: AppTheme.CARD_GAP }) {
      Row() {
        Text($r('app.string.backup_list_title'))
          .fontSize(AppTheme.FONT_SECTION)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
          .layoutWeight(1)
        Text($r('app.string.backup_cleanup'))
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(this.pending ? AppTheme.COLOR_TEXT_HINT : AppTheme.COLOR_PRIMARY)
          .onClick(() => {
            if (!this.pending) {
              this.onCleanup();
            }
          })
      }
      .width('100%')

      if (this.entries.length === 0) {
        EmptyView({ text: '还没有备份文件，先在设置页点「本地备份」' })
      } else {
        List({ space: 0 }) {
          ForEach(this.entries, (entry: FileEntry) => {
            ListItem() {
              Row({ space: AppTheme.CARD_GAP }) {
                Column({ space: 2 }) {
                  Text(entry.name)
                    .fontSize(AppTheme.FONT_BODY)
                    .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                  Text(`${Formatter.dateTime(entry.modifiedAt)} · ${Formatter.fileSize(entry.size)}`)
                    .fontSize(AppTheme.FONT_CAPTION)
                    .fontColor(AppTheme.COLOR_TEXT_HINT)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Text($r('app.string.common_delete'))
                  .fontSize(AppTheme.FONT_CAPTION)
                  .fontColor(AppTheme.COLOR_DANGER)
                  .onClick(() => this.onDelete(entry.path))
              }
              .width('100%')
              .padding({ top: 10, bottom: 10 })
            }
          }, (entry: FileEntry) => entry.path)
        }
        .height(240)
        .width('100%')
      }
    }
    .width('100%')
    .padding(AppTheme.PAGE_PADDING)
    .alignItems(HorizontalAlign.Start)
  }
}
