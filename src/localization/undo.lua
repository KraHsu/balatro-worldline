local keys={'Input queued; waiting for animation','Undo input queue is full',
    'Queued action cancelled: its cards or stage changed','Undo history limit reached',
    'Undo history ends at an unrecorded action'}
local rows={
 ['en-us']=keys,
 zh_CN={'操作已排队，等待动画完成','操作队列已满，请稍候','排队操作已取消：卡牌或阶段已改变','已到达本次游玩的撤回上限','撤回历史在一次未完整记录的操作处中断'},
 zh_TW={'操作已排隊，等待動畫完成','操作佇列已滿，請稍候','排隊操作已取消：卡牌或階段已改變','已到達本次遊玩的撤回上限','撤回歷史在一次未完整記錄的操作處中斷'},
 de={'Eingabe vorgemerkt; Animation abwarten','Eingabewarteschlange voll','Vorgemerkte Aktion abgebrochen: Karten oder Phase geändert','Ende des Rückgängig-Verlaufs erreicht','Verlauf endet an einer unvollständig aufgezeichneten Aktion'},
 es_ES={'Acción en cola; esperando animación','La cola de acciones está llena','Acción cancelada: cambiaron las cartas o la fase','Se alcanzó el límite de deshacer','El historial termina en una acción sin registro completo'},
 es_419={'Acción en cola; esperando animación','La cola de acciones está llena','Acción cancelada: cambiaron las cartas o la fase','Se alcanzó el límite de deshacer','El historial termina en una acción sin registro completo'},
 fr={'Action en attente de la fin de l\'animation','La file des actions est pleine','Action annulée : cartes ou phase modifiées','Limite du retour en arrière atteinte','Historique interrompu par une action incomplètement enregistrée'},
 id={'Aksi mengantre; menunggu animasi','Antrean aksi penuh','Aksi dibatalkan: kartu atau tahap berubah','Batas riwayat pembatalan tercapai','Riwayat berhenti pada aksi yang tidak terekam lengkap'},
 it={'Azione in coda; attesa animazione','La coda delle azioni è piena','Azione annullata: carte o fase cambiate','Limite della cronologia raggiunto','La cronologia termina con un\'azione registrata solo in parte'},
 ja={'操作を予約しました。アニメーション終了を待機中','操作予約がいっぱいです','カードまたは段階が変わったため予約をキャンセル','今回のプレイの取り消し上限に到達しました','記録が不完全な操作で取り消し履歴が途切れています'},
 ko={'입력 대기 중: 애니메이션이 끝나면 실행','입력 대기열이 가득 찼습니다','카드나 단계가 변경되어 대기 중인 작업 취소','되돌리기 기록 한도에 도달했습니다','완전히 기록되지 않은 작업에서 되돌리기 기록이 끊겼습니다'},
 nl={'Actie in wachtrij; wachten op animatie','De actiewachtrij is vol','Actie geannuleerd: kaarten of fase gewijzigd','Limiet voor ongedaan maken bereikt','Geschiedenis eindigt bij een onvolledig vastgelegde actie'},
 pl={'Akcja w kolejce; oczekiwanie na animację','Kolejka akcji jest pełna','Akcja anulowana: karty lub etap uległy zmianie','Osiągnięto limit historii cofania','Historia kończy się na niepełnym zapisie akcji'},
 pt_BR={'Ação na fila; aguardando animação','A fila de ações está cheia','Ação cancelada: cartas ou fase mudaram','Limite do histórico de desfazer atingido','O histórico termina em uma ação com registro incompleto'},
 ru={'Действие в очереди; ожидание анимации','Очередь действий заполнена','Действие отменено: карты или этап изменились','Достигнут предел истории отмены','История заканчивается на неполностью записанном действии'},
}
local catalog={}
for locale,row in pairs(rows)do
 assert(#row==#keys);catalog[locale]={}
 for i,key in ipairs(keys)do catalog[locale][key]=row[i]end
end
return {catalog=catalog}
