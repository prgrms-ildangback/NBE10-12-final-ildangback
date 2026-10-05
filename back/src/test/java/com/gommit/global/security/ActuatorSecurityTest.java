package com.gommit.global.security;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.test.web.servlet.MockMvc;

/**
 * 인프라(nginx / Docker HEALTHCHECK / 배포 스크립트 / GitHub Actions)가 전부
 * {@code GET /actuator/health} 를 인증 없이 호출한다. 이 계약이 깨지면 배포가 통째로 막힌다.
 * 동시에 그 외 actuator 엔드포인트는 절대 공개되면 안 된다(env·beans·configprops 로 시크릿 노출).
 *
 * {@code /actuator/prometheus} 는 Q29(모니터링)에서 permitAll 이지만 다른 "그 외"와 다르다 —
 * 도커 내부망의 prometheus 컨테이너만 실제로 닿을 수 있어(back 은 ports: 게시 없음, nginx도
 * 이 경로 프록시 안 함) permitAll 이어도 인터넷에 안 열린다. 그래서 별도 테스트로 뗀다.
 *
 * {@code /actuator/info} 의 {@code app.revision} 은 deploy.yml 이 배포 반영 확인에 쓴다.
 */
@SpringBootTest
@AutoConfigureMockMvc
class ActuatorSecurityTest {

    @Autowired
    private MockMvc mockMvc;

    @Test
    @DisplayName("GET /actuator/health 는 인증 없이 200")
    void healthIsPublic() throws Exception {
        // 막는 사고: SecurityConfig 의 HEALTH_ENDPOINTS permitAll 이 사라지거나 health 노출이 꺼지면
        //           → nginx healthcheck·Docker HEALTHCHECK·deploy.sh 헬스 대기·deploy.yml 최종 확인이
        //             전부 실패하고 배포가 롤백 루프에 빠진다.
        mockMvc.perform(get("/actuator/health")).andExpect(status().isOk());
    }

    @Test
    @DisplayName("GET /actuator/info 는 인증 없이 200, app.revision 포함")
    void infoIsPublicWithRevision() throws Exception {
        // 막는 사고: revision 을 못 읽으면 deploy.yml verify 가 매번 타임아웃.
        mockMvc.perform(get("/actuator/info"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.app.revision").exists());
    }

    @Test
    @DisplayName("health/info 외 actuator 엔드포인트는 인증 없이 접근 불가")
    void otherActuatorEndpointsAreNotPublic() throws Exception {
        // 막는 사고: 누가 management.endpoints.web.exposure.include 를 "*" 로 바꾸거나
        //           HEALTH_ENDPOINTS 매처를 "/actuator/**" 로 넓히면
        //           → env(환경변수·시크릿), configprops, beans, heapdump 가 무인증 공개된다.
        mockMvc.perform(get("/actuator")).andExpect(status().isUnauthorized());
        mockMvc.perform(get("/actuator/env")).andExpect(status().isUnauthorized());
        mockMvc.perform(get("/actuator/metrics")).andExpect(status().isUnauthorized());
        mockMvc.perform(get("/actuator/beans")).andExpect(status().isUnauthorized());
    }

    @Test
    @DisplayName("GET /actuator/prometheus 는 인증 없이 200 (Q29 — 도커 내부망 전용이라 안전)")
    void prometheusIsPublic() throws Exception {
        // 막는 사고: PROMETHEUS_ENDPOINT permitAll 이 사라지면 Prometheus 컨테이너의 스크랩이
        //           401 로 전부 실패해 메트릭이 통째로 공백된다.
        mockMvc.perform(get("/actuator/prometheus")).andExpect(status().isOk());
    }
}
