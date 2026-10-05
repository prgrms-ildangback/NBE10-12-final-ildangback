package com.gommit.domain.checkin.event;

import com.gommit.domain.checkin.media.CheckInMediaStore;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.scheduling.annotation.Async;
import org.springframework.stereotype.Component;
import org.springframework.transaction.event.TransactionPhase;
import org.springframework.transaction.event.TransactionalEventListener;

// 인증 트랜잭션 롤백 이후 orphan 미디어를 정리한다. 트랜잭션 경계 밖(비동기)에서 돌기 때문에
// 스토리지 삭제(동기 HTTP 왕복일 수 있음)가 DB 커넥션을 붙잡지 않는다.
@Slf4j
@Component
@RequiredArgsConstructor
public class OrphanMediaCleanupEventListener {

    private final CheckInMediaStore mediaStore;

    @Async
    @TransactionalEventListener(phase = TransactionPhase.AFTER_ROLLBACK)
    public void onOrphanMediaCleanup(OrphanMediaCleanupEvent event) {
        // @Async라 예외가 호출 스레드로 전파되지 않는다 - 여기서 안 잡으면 실패가 조용히 묻힌다.
        try {
            mediaStore.delete(event.mediaKey(), event.posterKey());
        } catch (RuntimeException e) {
            log.warn("orphan 미디어 정리 실패: mediaKey={}, posterKey={}", event.mediaKey(), event.posterKey(), e);
        }
    }
}
