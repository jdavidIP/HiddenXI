package com.hiddenxi.game;

import java.time.Duration;

import org.springframework.boot.context.properties.ConfigurationProperties;

/** Tunable game constants, bound from {@code hiddenxi.game.*} in application.yml. */
@ConfigurationProperties("hiddenxi.game")
public record GameProperties(
		int poolSize,
		int membersPerPrompt,
		int groupSizeMin,
		int groupSizeMax,
		double maxGroupJaccard,
		int guessBudget,
		Duration matchDuration,
		Duration minGuessInterval,
		Duration statementTimeout,
		Duration disconnectForfeitAfter) {
}
