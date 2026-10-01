package com.hiddenxi;

import static org.assertj.core.api.Assertions.assertThat;

import java.time.Duration;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.context.annotation.Import;
import org.springframework.test.web.servlet.assertj.MockMvcTester;

import com.hiddenxi.game.GameProperties;

@Import(TestcontainersConfiguration.class)
@SpringBootTest
@AutoConfigureMockMvc
class HiddenxiApplicationTests {

	@Autowired
	MockMvcTester mvc;

	@Autowired
	GameProperties game;

	@Test
	void healthIsPublicAndUp() {
		assertThat(mvc.get().uri("/actuator/health"))
				.hasStatusOk()
				.bodyJson().extractingPath("$.status").isEqualTo("UP");
	}

	@Test
	void otherEndpointsAreDenied() {
		// No login mechanism exists yet, so Spring Security answers 403 rather than 401.
		assertThat(mvc.get().uri("/api/anything")).hasStatus(403);
	}

	@Test
	void gameDefaultsBindFromApplicationYml() {
		assertThat(game.poolSize()).isEqualTo(500);
		assertThat(game.maxGroupJaccard()).isEqualTo(0.3);
		assertThat(game.matchDuration()).isEqualTo(Duration.ofMinutes(15));
		assertThat(game.minGuessInterval()).isEqualTo(Duration.ofMillis(1500));
	}

}
