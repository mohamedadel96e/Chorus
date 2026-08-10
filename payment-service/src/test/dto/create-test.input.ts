import { InputType, Int, Field } from '@nestjs/graphql';

@InputType()
export class CreateTestInput {
  @Field(() => Int, { description: 'Example field (placeholder)' })
  exampleField: number;
}
