local keys={'Video output directory','Default recording directory','Background export; your current run stays paused.',
    'Cancel export','Preparing video renderer','Starting video renderer','Rendering video','Encoding video','Cancelling export'}
local rows={
 ['en-us']={'Video output directory','Default recording directory','Background export; your current run stays paused.','Cancel export','Preparing video renderer','Starting video renderer','Rendering video','Encoding video','Cancelling export'},
 zh_CN={'视频导出目录','默认录制目录','后台导出期间，当前牌局保持暂停。','取消导出','准备导出环境','启动导出','生成视频画面','编码视频','正在取消导出'},
 zh_TW={'影片匯出目錄','預設錄製目錄','背景匯出期間，目前牌局保持暫停。','取消匯出','準備匯出環境','啟動匯出','產生影片畫面','編碼影片','正在取消匯出'},
 de={'Video-Ausgabeordner','Standard-Aufnahmeordner','Export im Hintergrund; dein Lauf bleibt pausiert.','Export abbrechen','Renderer vorbereiten','Renderer starten','Video rendern','Video kodieren','Export wird abgebrochen'},
 es_ES={'Carpeta de vídeo','Carpeta predeterminada','Exportación en segundo plano; la partida sigue en pausa.','Cancelar exportación','Preparando el renderizador','Iniciando el renderizador','Generando vídeo','Codificando vídeo','Cancelando exportación'},
 es_419={'Carpeta de video','Carpeta predeterminada','Exportación en segundo plano; la partida sigue en pausa.','Cancelar exportación','Preparando el renderizador','Iniciando el renderizador','Generando video','Codificando video','Cancelando exportación'},
 fr={'Dossier vidéo','Dossier par défaut','Export en arrière-plan ; votre partie reste en pause.','Annuler l\'export','Préparation du rendu','Démarrage du rendu','Création des images','Encodage vidéo','Annulation de l\'export'},
 id={'Folder keluaran video','Folder rekaman bawaan','Ekspor di latar belakang; permainan tetap dijeda.','Batalkan ekspor','Menyiapkan perender','Memulai perender','Merender video','Mengodekan video','Membatalkan ekspor'},
 it={'Cartella video','Cartella predefinita','Esportazione in background; la partita resta in pausa.','Annulla esportazione','Preparazione del rendering','Avvio del rendering','Rendering video','Codifica video','Annullamento esportazione'},
 ja={'動画の出力先','既定の録画フォルダー','バックグラウンドで出力中。ゲームは一時停止します。','出力を中止','出力環境を準備中','出力を開始中','動画を描画中','動画をエンコード中','出力を中止中'},
 ko={'영상 출력 폴더','기본 녹화 폴더','백그라운드 내보내기 중입니다. 게임은 일시 정지됩니다.','내보내기 취소','렌더러 준비 중','렌더러 시작 중','영상 렌더링 중','영상 인코딩 중','내보내기 취소 중'},
 nl={'Video-uitvoermap','Standaard opnamemap','Export op de achtergrond; je spel blijft gepauzeerd.','Export annuleren','Renderer voorbereiden','Renderer starten','Video renderen','Video coderen','Export annuleren'},
 pl={'Folder wyjściowy filmu','Domyślny folder nagrań','Eksport w tle; rozgrywka pozostaje wstrzymana.','Anuluj eksport','Przygotowanie renderera','Uruchamianie renderera','Renderowanie filmu','Kodowanie filmu','Anulowanie eksportu'},
 pt_BR={'Pasta de saída do vídeo','Pasta padrão de gravação','Exportação em segundo plano; a partida fica pausada.','Cancelar exportação','Preparando renderizador','Iniciando renderizador','Renderizando vídeo','Codificando vídeo','Cancelando exportação'},
 ru={'Папка для видео','Стандартная папка записи','Экспорт в фоне; игра остаётся на паузе.','Отменить экспорт','Подготовка рендера','Запуск рендера','Отрисовка видео','Кодирование видео','Отмена экспорта'},
}
local catalog={}
local labels={
 ['en-us']={'actions','Video time'},zh_CN={'操作','视频时长'},zh_TW={'操作','影片時長'},
 de={'Aktionen','Videodauer'},es_ES={'acciones','Duración'},es_419={'acciones','Duración'},
 fr={'actions','Durée vidéo'},id={'tindakan','Durasi video'},it={'azioni','Durata video'},
 ja={'操作','動画時間'},ko={'행동','영상 시간'},nl={'acties','Videoduur'},
 pl={'działań','Czas filmu'},pt_BR={'ações','Duração'},ru={'действий','Время видео'},
}
for locale,row in pairs(rows) do
    assert(#row==#keys);catalog[locale]={}
    for i,key in ipairs(keys) do catalog[locale][key]=row[i] end
    catalog[locale]['Recorded actions']=labels[locale][1]
    catalog[locale]['Video time']=labels[locale][2]
end
return {catalog=catalog}
