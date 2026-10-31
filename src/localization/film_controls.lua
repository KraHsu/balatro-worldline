local keys={'Video resolution','2K uses more GPU memory, encoding time and output disk space.',
    'Enter path','Choose FFmpeg executable','Choose video output folder'}
local rows={
 ['en-us']={'Video resolution','2K uses more GPU memory, encoding time and output disk space.','Enter path','Choose FFmpeg executable','Choose video output folder'},
 zh_CN={'输出尺寸','2K 会明显增加显存、编码耗时和输出文件占用。','输入','选择 FFmpeg 程序','选择视频导出目录'},
 zh_TW={'輸出尺寸','2K 會明顯增加顯示記憶體、編碼時間和輸出檔案空間。','輸入','選擇 FFmpeg 程式','選擇影片匯出目錄'},
 de={'Videoauflösung','2K benötigt mehr Grafikspeicher, Kodierzeit und Ausgabespeicher.','Eingeben','FFmpeg-Programm wählen','Video-Ausgabeordner wählen'},
 es_ES={'Resolución','2K requiere más memoria gráfica, tiempo y espacio de salida.','Escribir','Elegir ejecutable de FFmpeg','Elegir carpeta de vídeo'},
 es_419={'Resolución','2K requiere más memoria gráfica, tiempo y espacio de salida.','Escribir','Elegir ejecutable de FFmpeg','Elegir carpeta de video'},
 fr={'Résolution','2K utilise plus de mémoire graphique, de temps et de disque de sortie.','Saisir','Choisir le programme FFmpeg','Choisir le dossier vidéo'},
 id={'Resolusi video','2K memakai lebih banyak memori GPU, waktu, dan ruang disk keluaran.','Ketik','Pilih program FFmpeg','Pilih folder keluaran video'},
 it={'Risoluzione','2K richiede più memoria GPU, tempo e spazio di uscita.','Scrivi','Scegli eseguibile FFmpeg','Scegli cartella video'},
 ja={'出力解像度','2KはGPUメモリ、処理時間、出力ディスク容量を多く使用します。','入力','FFmpegの実行ファイルを選択','動画の出力先を選択'},
 ko={'영상 해상도','2K는 GPU 메모리, 인코딩 시간과 출력 디스크 공간을 더 사용합니다.','입력','FFmpeg 실행 파일 선택','영상 출력 폴더 선택'},
 nl={'Videoresolutie','2K vraagt meer GPU-geheugen, codeertijd en uitvoerschijfruimte.','Invoer','Kies FFmpeg-programma','Kies video-uitvoermap'},
 pl={'Rozdzielczość','2K zużywa więcej pamięci GPU, czasu i miejsca na plik wynikowy.','Wpisz','Wybierz program FFmpeg','Wybierz folder filmu'},
 pt_BR={'Resolução','2K usa mais memória da GPU, tempo e espaço de saída.','Digitar','Escolher executável FFmpeg','Escolher pasta do vídeo'},
 ru={'Разрешение','2K требует больше видеопамяти, времени и места для видео.','Ввод','Выберите программу FFmpeg','Выберите папку для видео'},
}
local catalog={}
local warning='Some action records are incomplete; playback order may differ from actual play.'
local warnings={
 ['en-us']=warning,zh_CN='部分操作记录不完整，录像中的操作顺序可能与实际游玩不同。',
 zh_TW='部分操作記錄不完整，影片中的操作順序可能與實際遊玩不同。',
 de='Einige Aktionsdaten fehlen; die Wiedergabereihenfolge kann vom Spiel abweichen.',
 es_ES='Faltan algunos datos; el orden del vídeo puede diferir de la partida.',
 es_419='Faltan algunos datos; el orden del video puede diferir de la partida.',
 fr='Certaines actions sont incomplètes ; leur ordre peut différer de la partie.',
 id='Sebagian catatan tidak lengkap; urutan video mungkin berbeda dari permainan.',
 it="Alcuni dati sono incompleti; l'ordine del video può differire dalla partita.",
 ja='一部の操作記録が不完全なため、動画の操作順が実際と異なる場合があります。',
 ko='일부 행동 기록이 불완전하여 영상의 행동 순서가 실제 플레이와 다를 수 있습니다.',
 nl='Sommige actiegegevens ontbreken; de volgorde kan afwijken van het spel.',
 pl='Część zapisów jest niepełna; kolejność w filmie może różnić się od gry.',
 pt_BR='Alguns registros estão incompletos; a ordem do vídeo pode diferir da partida.',
 ru='Некоторые записи неполны; порядок действий в видео может отличаться от игры.',
}
local rewards={['en-us']='Other rewards',zh_CN='其他奖励',zh_TW='其他獎勵',de='Weitere Belohnungen',
 es_ES='Otras recompensas',es_419='Otras recompensas',fr='Autres récompenses',id='Hadiah lainnya',
 it='Altre ricompense',ja='その他の報酬',ko='기타 보상',nl='Overige beloningen',pl='Inne nagrody',
 pt_BR='Outras recompensas',ru='Другие награды'}
for locale,row in pairs(rows) do
    assert(#row==#keys);catalog[locale]={}
    for i,key in ipairs(keys) do catalog[locale][key]=row[i] end
    catalog[locale]['Other rewards']=rewards[locale]
    catalog[locale][warning]=assert(warnings[locale])
end
return {catalog=catalog}
