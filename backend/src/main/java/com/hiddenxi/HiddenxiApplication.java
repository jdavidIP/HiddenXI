package com.hiddenxi;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.ConfigurationPropertiesScan;

@SpringBootApplication
@ConfigurationPropertiesScan
public class HiddenxiApplication {

	public static void main(String[] args) {
		SpringApplication.run(HiddenxiApplication.class, args);
	}

}
