-- Rows share an explicit key order; every native language has a full row.
local keys={'Record video','Recording endpoints','Start point','End point','Use selected points',
    'Game speed','Frame rate','Card information','Pause before consumables','Show every pack card',
    'Information pause','Action delay','FFmpeg path','Export video','Select two points on one route',
    'Video has no audio. Esc cancels and restores your run.','Video saved','Recording cancelled'}
local rows={
 ['en-us']={'Record video','Recording endpoints','Start point','End point','Use selected points','Game speed','Frame rate','Card information','Pause before consumables','Show every pack card','Information pause','Action delay','FFmpeg path','Export video','Select two points on one route','Video has no audio. Esc cancels and restores your run.','Video saved','Recording cancelled'},
 zh_CN={'录制','录制范围','开始节点','结束节点','使用选中节点','游戏速度','帧率','卡牌信息','使用消耗牌前停顿','展示卡包全部卡牌','信息停顿时间','操作间隔','FFmpeg 路径','导出视频','请选择同一路线上的两个节点','视频不含声音；Esc 取消并恢复牌局。','视频已保存','已取消录制'},
 zh_TW={'錄製','錄製範圍','開始節點','結束節點','使用選取節點','遊戲速度','幀率','卡牌資訊','使用消耗牌前停頓','展示卡包全部卡牌','資訊停頓時間','操作間隔','FFmpeg 路徑','匯出影片','請選擇同一路線上的兩個節點','影片不含聲音；Esc 取消並恢復牌局。','影片已儲存','已取消錄製'},
 de={'Video aufnehmen','Aufnahmebereich','Startpunkt','Endpunkt','Auswahl verwenden','Spieltempo','Bildrate','Karteninformationen','Pause vor Verbrauch','Alle Packkarten zeigen','Infopause','Aktionsabstand','FFmpeg-Pfad','Video exportieren','Zwei Punkte derselben Route wählen','Video ohne Ton. Esc bricht ab und stellt den Lauf wieder her.','Video gespeichert','Aufnahme abgebrochen'},
 es_ES={'Grabar vídeo','Rango de grabación','Punto inicial','Punto final','Usar selección','Velocidad del juego','Fotogramas','Información de cartas','Pausa antes de consumibles','Mostrar todas las cartas','Pausa informativa','Intervalo de acciones','Ruta de FFmpeg','Exportar vídeo','Elige dos puntos de la misma ruta','Vídeo sin audio. Esc cancela y restaura la partida.','Vídeo guardado','Grabación cancelada'},
 es_419={'Grabar video','Rango de grabación','Punto inicial','Punto final','Usar selección','Velocidad del juego','Fotogramas','Información de cartas','Pausa antes de consumibles','Mostrar todas las cartas','Pausa informativa','Intervalo de acciones','Ruta de FFmpeg','Exportar video','Elige dos puntos de la misma ruta','Video sin audio. Esc cancela y restaura la partida.','Video guardado','Grabación cancelada'},
 fr={'Enregistrer','Plage vidéo','Point de départ','Point de fin','Utiliser la sélection','Vitesse du jeu','Images par seconde','Informations des cartes','Pause avant consommable','Montrer toutes les cartes','Pause informative','Délai entre actions','Chemin FFmpeg','Exporter la vidéo','Choisir deux points du même trajet','Vidéo sans son. Échap annule et restaure la partie.','Vidéo enregistrée','Enregistrement annulé'},
 id={'Rekam video','Rentang rekaman','Titik awal','Titik akhir','Gunakan pilihan','Kecepatan permainan','Laju bingkai','Informasi kartu','Jeda sebelum konsumabel','Tampilkan semua kartu pak','Jeda informasi','Jeda tindakan','Lokasi FFmpeg','Ekspor video','Pilih dua titik pada rute yang sama','Video tanpa suara. Esc membatalkan dan memulihkan permainan.','Video disimpan','Rekaman dibatalkan'},
 it={'Registra video','Intervallo video','Punto iniziale','Punto finale','Usa selezione','Velocità di gioco','Fotogrammi','Informazioni carte','Pausa prima dei consumabili','Mostra tutte le carte','Pausa informazioni','Intervallo azioni','Percorso FFmpeg','Esporta video','Scegli due punti dello stesso percorso','Video senza audio. Esc annulla e ripristina la partita.','Video salvato','Registrazione annullata'},
 ja={'録画','録画範囲','開始地点','終了地点','選択した地点を使用','ゲーム速度','フレームレート','カード情報','消耗品の使用前に停止','パックの全カードを表示','情報の表示時間','操作の間隔','FFmpeg のパス','動画を書き出す','同じ経路の２地点を選択','音声なし。Escで中止して元の状態に戻ります。','動画を保存しました','録画を中止しました'},
 ko={'영상 녹화','녹화 구간','시작 지점','종료 지점','선택한 지점 사용','게임 속도','프레임 속도','카드 정보','소모품 사용 전 일시 정지','팩의 모든 카드 표시','정보 표시 시간','행동 간격','FFmpeg 경로','영상 내보내기','같은 경로의 두 지점을 선택하세요','소리 없는 영상입니다. Esc로 취소하고 복원합니다.','영상 저장 완료','녹화 취소'},
 nl={'Video opnemen','Opnamebereik','Beginpunt','Eindpunt','Selectie gebruiken','Spelsnelheid','Beeldsnelheid','Kaartinformatie','Pauze voor verbruik','Alle kaarten tonen','Informatiepauze','Actie-interval','FFmpeg-pad','Video exporteren','Kies twee punten op dezelfde route','Video zonder geluid. Esc annuleert en herstelt je spel.','Video opgeslagen','Opname geannuleerd'},
 pl={'Nagraj film','Zakres nagrania','Punkt początkowy','Punkt końcowy','Użyj zaznaczenia','Szybkość gry','Klatki na sekundę','Informacje o kartach','Pauza przed zużyciem','Pokaż wszystkie karty','Czas informacji','Odstęp działań','Ścieżka FFmpeg','Eksportuj film','Wybierz dwa punkty na tej samej trasie','Film bez dźwięku. Esc anuluje i przywraca grę.','Film zapisany','Nagrywanie anulowane'},
 pt_BR={'Gravar vídeo','Intervalo da gravação','Ponto inicial','Ponto final','Usar seleção','Velocidade do jogo','Taxa de quadros','Informações das cartas','Pausar antes de consumíveis','Mostrar todas as cartas','Pausa de informações','Intervalo de ações','Caminho do FFmpeg','Exportar vídeo','Escolha dois pontos da mesma rota','Vídeo sem áudio. Esc cancela e restaura a partida.','Vídeo salvo','Gravação cancelada'},
 ru={'Запись видео','Диапазон записи','Начальная точка','Конечная точка','Использовать выбор','Скорость игры','Частота кадров','Информация о картах','Пауза перед расходником','Показать все карты набора','Время показа','Интервал действий','Путь к FFmpeg','Экспорт видео','Выберите две точки одного пути','Видео без звука. Esc отменяет запись и восстанавливает игру.','Видео сохранено','Запись отменена'},
}
local catalog={}
local error_keys={'This route has incomplete action records','Recording end must descend from its start','Start or load a run before recording'}
local errors={
 ['en-us']={'This route has incomplete action records','Recording end must descend from its start','Start or load a run before recording'},
 zh_CN={'这段路线的操作记录不完整，无法录制','结束节点必须位于开始节点的后续路线','请先开始一局或载入世界线，再进行录制'},
 zh_TW={'這段路線的操作記錄不完整，無法錄製','結束節點必須位於開始節點的後續路線','請先開始一局或載入世界線，再進行錄製'},
 de={'Dieser Route fehlen Aktionsdaten','Das Ende muss dem Start nachfolgen','Vor der Aufnahme einen Lauf starten oder laden'},
 es_ES={'Faltan acciones en esta ruta','El final debe descender del inicio','Inicia o carga una partida antes de grabar'},
 es_419={'Faltan acciones en esta ruta','El final debe descender del inicio','Inicia o carga una partida antes de grabar'},
 fr={'Les actions de ce trajet sont incomplètes','La fin doit suivre le départ','Démarrez ou chargez une partie avant de filmer'},
 id={'Catatan tindakan rute ini tidak lengkap','Titik akhir harus mengikuti titik awal','Mulai atau muat permainan sebelum merekam'},
 it={'Le azioni di questo percorso sono incomplete','La fine deve seguire il punto iniziale','Avvia o carica una partita prima di registrare'},
 ja={'この経路の操作記録が不足しています','終了地点は開始地点の後にしてください','録画の前にゲームを開始するか読み込んでください'},
 ko={'이 경로의 행동 기록이 부족합니다','종료 지점은 시작 지점의 후속 경로여야 합니다','녹화 전에 게임을 시작하거나 불러오세요'},
 nl={'Deze route mist actiegegevens','Het eindpunt moet na het beginpunt liggen','Start of laad een spel voor de opname'},
 pl={'Ta trasa ma niepełne dane działań','Koniec musi następować po początku','Rozpocznij lub wczytaj grę przed nagrywaniem'},
 pt_BR={'Faltam ações nesta rota','O final deve seguir o ponto inicial','Inicie ou carregue uma partida antes de gravar'},
 ru={'В этом пути не хватает записей действий','Конец должен следовать за началом','Начните или загрузите игру перед записью'},
}
for locale,row in pairs(rows) do
    assert(#row==#keys,'Incomplete video translation: '..locale)
    catalog[locale]={}
    for i,key in ipairs(keys) do catalog[locale][key]=row[i] end
    for i,key in ipairs(error_keys) do catalog[locale][key]=assert(errors[locale][i]) end
end
return {catalog=catalog}
